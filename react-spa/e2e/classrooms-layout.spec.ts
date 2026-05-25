import { expect, test, type Locator, type Page, type Route } from '@playwright/test';

import { loginAsAdmin, waitForNetworkIdle } from './fixtures/test-utils';

const classrooms = Array.from({ length: 24 }, (_, index) => ({
  id: `layout-room-${index + 1}`,
  name: `Layout Room ${String(index + 1).padStart(2, '0')}`,
  displayName: `Layout Room ${String(index + 1).padStart(2, '0')}`,
  defaultGroupId: 'layout-group',
  defaultGroupDisplayName: 'Layout Group',
  activeGroup: null,
  activeGroupId: null,
  currentGroupId: 'layout-group',
  currentGroupDisplayName: 'Layout Group',
  currentGroupSource: 'default',
  status: index % 5 === 0 ? 'degraded' : 'operational',
  machineCount: 8,
  onlineMachineCount: 6,
  computerCount: 8,
  machines: Array.from({ length: 8 }, (_, machineIndex) => ({
    id: `layout-room-${index + 1}-machine-${machineIndex + 1}`,
    hostname: `layout-${index + 1}-${machineIndex + 1}`,
    lastSeen: '2026-05-21T08:00:00.000Z',
    status: machineIndex < 6 ? 'online' : 'offline',
  })),
}));

const schedules = Array.from({ length: 10 }, (_, index) => ({
  id: `layout-schedule-${index + 1}`,
  classroomId: 'layout-room-1',
  dayOfWeek: (index % 5) + 1,
  startTime: `${String(8 + (index % 8)).padStart(2, '0')}:00`,
  endTime: `${String(9 + (index % 8)).padStart(2, '0')}:00`,
  groupId: 'layout-group',
  groupDisplayName: 'Layout Group',
  teacherId: 'layout-teacher',
  teacherName: 'Layout Teacher',
  recurrence: 'weekly',
  createdAt: '2026-05-21T08:00:00.000Z',
  isMine: true,
  canEdit: true,
}));

const layoutGroup = {
  id: 'layout-group',
  name: 'layout-group',
  displayName: 'Layout Group',
  enabled: true,
};

function setJson(entry: unknown, value: unknown): unknown {
  if (!entry || typeof entry !== 'object') return entry;
  const e = entry as { result?: { data?: unknown } };
  if (!e.result || typeof e.result !== 'object') return entry;
  const result = e.result as { data?: unknown };
  if (result.data && typeof result.data === 'object' && 'json' in result.data) {
    (result.data as { json?: unknown }).json = value;
  } else {
    result.data = value;
  }
  return entry;
}

function patchTrpcEntry(entry: unknown, procedure: string): unknown {
  switch (procedure) {
    case 'classrooms.list':
      return setJson(entry, classrooms);
    case 'classrooms.listExemptions':
      return setJson(entry, []);
    case 'groups.list':
      return setJson(entry, [layoutGroup]);
    case 'schedules.getByClassroom':
      return setJson(entry, { schedules, oneOffSchedules: [] });
    default:
      return entry;
  }
}

async function patchClassroomsLayoutData(route: Route): Promise<void> {
  const url = new URL(route.request().url());
  const marker = '/trpc/';
  const markerIndex = url.pathname.indexOf(marker);
  if (markerIndex < 0) {
    await route.continue();
    return;
  }

  const proceduresPart = url.pathname.slice(markerIndex + marker.length);
  const procedures = proceduresPart.split(',').filter(Boolean);

  const response = await route.fetch();
  const contentType = response.headers()['content-type'] || '';
  if (!contentType.includes('application/json')) {
    await route.fulfill({ response });
    return;
  }

  const originalBody: unknown = await response.json();
  const patchedBody = Array.isArray(originalBody)
    ? originalBody.map((entry, index) => patchTrpcEntry(entry, procedures[index] ?? proceduresPart))
    : patchTrpcEntry(originalBody, proceduresPart);

  await route.fulfill({ response, json: patchedBody });
}

async function installClassroomsLayoutPatch(page: Page): Promise<void> {
  await page.route(/\/trpc(\/|$)/, patchClassroomsLayoutData);
}

async function navigateToClassrooms(page: Page): Promise<void> {
  const menuButton = page.getByRole('button', { name: /Abrir menú|Open menu/i });
  if (await menuButton.isVisible({ timeout: 500 }).catch(() => false)) {
    const sidebar = page.locator('aside').first();
    const sidebarClosed = await sidebar
      .evaluate((el) => el.className.includes('-translate-x-full'))
      .catch(() => false);
    if (sidebarClosed) {
      await menuButton.click();
      await expect(sidebar).not.toHaveClass(/-translate-x-full/);
    }
  }

  await page
    .getByRole('button', { name: /Secure Classrooms|Aulas Seguras|Classrooms|Aulas/i })
    .click();
  await waitForNetworkIdle(page).catch(() => {});
  await expect(page.getByRole('heading', { name: 'Layout Room 01', level: 2 })).toBeVisible();
}

async function getClassroomListScrollArea(page: Page): Promise<Locator> {
  const roomOne = page.locator('h3').filter({ hasText: 'Layout Room 01' });
  await expect(roomOne).toBeVisible();
  return page.locator('div.custom-scrollbar').filter({ hasText: 'Layout Room 01' }).first();
}

test.describe('Classrooms split-view layout', () => {
  test.beforeEach(async ({ page }) => {
    await installClassroomsLayoutPatch(page);
    await loginAsAdmin(page);
  });

  test('keeps desktop scrolling inside the split-view panes', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await navigateToClassrooms(page);

    const documentScroll = await page.evaluate(() => ({
      scrollHeight: document.documentElement.scrollHeight,
      clientHeight: document.documentElement.clientHeight,
      bodyScrollHeight: document.body.scrollHeight,
      bodyClientHeight: document.body.clientHeight,
    }));
    expect(documentScroll.scrollHeight).toBeLessThanOrEqual(documentScroll.clientHeight + 2);
    expect(documentScroll.bodyScrollHeight).toBeLessThanOrEqual(
      documentScroll.bodyClientHeight + 2
    );

    const mainScroll = await page.getByTestId('openpath-shell-main').evaluate((main) => ({
      scrollHeight: main.scrollHeight,
      clientHeight: main.clientHeight,
      overflowY: window.getComputedStyle(main).overflowY,
    }));
    expect(mainScroll.overflowY).toBe('hidden');
    expect(mainScroll.scrollHeight).toBeLessThanOrEqual(mainScroll.clientHeight + 2);

    const listScrollArea = await getClassroomListScrollArea(page);
    const listMetrics = await listScrollArea.evaluate((list) => ({
      scrollHeight: list.scrollHeight,
      clientHeight: list.clientHeight,
      before: list.scrollTop,
    }));
    expect(listMetrics.scrollHeight).toBeGreaterThan(listMetrics.clientHeight + 100);

    await listScrollArea.evaluate((list) => {
      list.scrollTop = list.scrollHeight;
    });
    await expect(page.getByText('Layout Room 24', { exact: true })).toBeVisible();

    const scrolledTop = await listScrollArea.evaluate((list) => list.scrollTop);
    expect(scrolledTop).toBeGreaterThan(listMetrics.before);
    await expect(page.getByRole('heading', { name: 'Layout Room 01', level: 2 })).toBeVisible();

    await page.getByRole('tab', { name: /Schedule/i }).click();
    await expect(page.getByRole('tabpanel', { name: /Schedule/i })).toBeVisible();
    await expect(page.getByText('Classroom Schedule')).toBeVisible();
    await expect(page.getByText('Layout Group').first()).toBeVisible();

    const schedulePanelBox = await page.locator('#classroom-detail-panel-schedule').boundingBox();
    const calendarBox = await page.getByText('Classroom Schedule').boundingBox();
    expect(schedulePanelBox).not.toBeNull();
    expect(calendarBox).not.toBeNull();
    expect(calendarBox!.y).toBeGreaterThanOrEqual(schedulePanelBox!.y);
    expect(calendarBox!.y).toBeLessThan(800);
  });

  test('keeps mobile layout vertical with usable tabs', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await navigateToClassrooms(page);

    const mobileScroll = await page.getByTestId('openpath-shell-main').evaluate((main) => ({
      scrollHeight: main.scrollHeight,
      clientHeight: main.clientHeight,
      overflowY: window.getComputedStyle(main).overflowY,
    }));
    expect(mobileScroll.overflowY).toBe('auto');
    expect(mobileScroll.scrollHeight).toBeGreaterThanOrEqual(mobileScroll.clientHeight);

    await page.getByRole('tab', { name: /Schedule/i }).scrollIntoViewIfNeeded();
    await page.getByRole('tab', { name: /Schedule/i }).click();
    const schedulePanel = page.locator('#classroom-detail-panel-schedule');
    await expect(schedulePanel).toBeVisible();
    await expect(page.getByText('Classroom Schedule')).toBeVisible();

    const tabBox = await page.getByRole('tab', { name: /Schedule/i }).boundingBox();
    const panelBox = await schedulePanel.boundingBox();
    expect(tabBox).not.toBeNull();
    expect(panelBox).not.toBeNull();
    expect(tabBox!.y + tabBox!.height).toBeLessThanOrEqual(panelBox!.y + 4);
  });

  test('keeps compact layouts usable when the classroom list is long', async ({ page }) => {
    for (const width of [760, 900]) {
      await page.setViewportSize({ width, height: 800 });
      await navigateToClassrooms(page);

      const listScrollArea = await getClassroomListScrollArea(page);
      const listMetrics = await listScrollArea.evaluate((list) => ({
        scrollHeight: list.scrollHeight,
        clientHeight: list.clientHeight,
        overflowY: window.getComputedStyle(list).overflowY,
      }));
      expect(listMetrics.overflowY).toBe('auto');
      expect(listMetrics.scrollHeight).toBeGreaterThan(listMetrics.clientHeight + 100);
      expect(listMetrics.clientHeight).toBeLessThanOrEqual(360);

      const tabListBox = await page
        .getByRole('tablist', { name: /classroom detail sections/i })
        .boundingBox();
      expect(tabListBox).not.toBeNull();
      expect(tabListBox!.y).toBeLessThan(760);

      const tabListOverflow = await page
        .getByRole('tablist', { name: /classroom detail sections/i })
        .evaluate((tabList) => ({
          overflowX: window.getComputedStyle(tabList).overflowX,
          overflowY: window.getComputedStyle(tabList).overflowY,
          scrollHeight: tabList.scrollHeight,
          clientHeight: tabList.clientHeight,
        }));
      expect(tabListOverflow.overflowX).toBe('auto');
      expect(tabListOverflow.overflowY).toBe('hidden');
      expect(tabListOverflow.scrollHeight).toBeLessThanOrEqual(tabListOverflow.clientHeight + 2);
    }
  });
});
