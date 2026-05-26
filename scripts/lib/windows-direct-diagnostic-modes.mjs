const DEFAULT_RUNNER_ROOT_GLOB = 'C:\\actions-runner*';

const WINDOWS_DIRECT_DIAGNOSTIC_MODES = Object.freeze({
  pester: Object.freeze({
    mode: 'pester',
    artifactRoot: `${DEFAULT_RUNNER_ROOT_GLOB}\\_work\\Openpath\\Openpath`,
    completionFileName: 'windows-test-results.xml',
    runnerScriptPath: 'windows\\tests\\Invoke-IsolatedPester.ps1',
    requiresSharedPowerShellPreamble: false,
  }),
  'browser-boundary': Object.freeze({
    mode: 'browser-boundary',
    artifactRoot: `${DEFAULT_RUNNER_ROOT_GLOB}\\_work\\Openpath\\Openpath\\tests\\e2e\\artifacts\\windows-student-policy`,
    completionFileName: 'direct-browser-boundary-completion.json',
    runnerScriptPath: 'tests\\e2e\\ci\\run-windows-browser-boundary-ci.ps1',
    requiresSharedPowerShellPreamble: true,
  }),
  'dns-discovery-spike': Object.freeze({
    mode: 'dns-discovery-spike',
    artifactRoot: 'C:\\Windows\\Temp\\openpath-dns-discovery-spike',
    completionFileName: 'direct-dns-discovery-spike-completion.json',
    runnerScriptPath: 'tests\\e2e\\ci\\run-windows-dns-discovery-spike.ps1',
    requiresSharedPowerShellPreamble: true,
  }),
  'dns-evidence-matrix': Object.freeze({
    mode: 'dns-evidence-matrix',
    artifactRoot: 'C:\\Windows\\Temp\\openpath-dns-evidence-matrix',
    completionFileName: 'direct-dns-evidence-matrix-completion.json',
    runnerScriptPath: 'tests\\e2e\\ci\\run-windows-dns-evidence-matrix.ps1',
    requiresSharedPowerShellPreamble: true,
  }),
  'dns-evidence-matrix-v2': Object.freeze({
    mode: 'dns-evidence-matrix-v2',
    artifactRoot: 'C:\\Windows\\Temp\\openpath-dns-evidence-matrix-v2',
    completionFileName: 'direct-dns-evidence-matrix-v2-completion.json',
    runnerScriptPath: 'tests\\e2e\\ci\\run-windows-dns-evidence-matrix-v2.ps1',
    requiresSharedPowerShellPreamble: true,
  }),
  'dns-observability-controls': Object.freeze({
    mode: 'dns-observability-controls',
    artifactRoot: 'C:\\Windows\\Temp\\openpath-dns-observability-controls',
    completionFileName: 'direct-dns-observability-controls-completion.json',
    runnerScriptPath: 'tests\\e2e\\ci\\run-windows-dns-observability-controls.ps1',
    requiresSharedPowerShellPreamble: true,
  }),
  'acrylic-purgecache-spike': Object.freeze({
    mode: 'acrylic-purgecache-spike',
    artifactRoot: 'C:\\Windows\\Temp\\openpath-acrylic-purgecache-spike',
    completionFileName: 'direct-acrylic-purgecache-spike-completion.json',
    runnerScriptPath: 'tests\\e2e\\ci\\run-windows-acrylic-purgecache-spike.ps1',
    requiresSharedPowerShellPreamble: true,
  }),
  'browser-dependency-observability-spike': Object.freeze({
    mode: 'browser-dependency-observability-spike',
    artifactRoot: 'C:\\Windows\\Temp\\openpath-browser-dependency-observability-spike',
    completionFileName: 'direct-browser-dependency-observability-spike-completion.json',
    runnerScriptPath: 'tests\\e2e\\ci\\run-windows-browser-dependency-observability-spike.ps1',
    requiresSharedPowerShellPreamble: true,
  }),
  'captive-portal-navigation': Object.freeze({
    mode: 'captive-portal-navigation',
    artifactRoot: 'C:\\Windows\\Temp\\openpath-captive-portal-navigation',
    completionFileName: 'direct-captive-portal-navigation-completion.json',
    runnerScriptPath: 'tests\\e2e\\ci\\run-windows-captive-portal-navigation.ps1',
    requiresSharedPowerShellPreamble: true,
  }),
  'captive-portal-wedu-lab': Object.freeze({
    mode: 'captive-portal-wedu-lab',
    artifactRoot: 'C:\\Windows\\Temp\\openpath-captive-portal-wedu-lab',
    completionFileName: 'direct-captive-portal-wedu-lab-completion.json',
    runnerScriptPath: 'tests\\e2e\\ci\\run-windows-captive-portal-wedu-lab.ps1',
    requiresSharedPowerShellPreamble: true,
    skipPreRunReset: true,
    includeInAll: false,
    allowLocalOverlay: false,
  }),
});

const WINDOWS_DIRECT_RUN_MODE_NAMES = Object.freeze([
  ...Object.keys(WINDOWS_DIRECT_DIAGNOSTIC_MODES),
  'all',
]);

function resolveWindowsDirectDiagnosticMode(mode) {
  const metadata = WINDOWS_DIRECT_DIAGNOSTIC_MODES[mode];
  if (!metadata) {
    throw new Error(
      `Invalid Windows direct diagnostic mode ${JSON.stringify(mode)}. Expected one of: ${WINDOWS_DIRECT_RUN_MODE_NAMES.join(', ')}`
    );
  }
  return metadata;
}

export {
  WINDOWS_DIRECT_DIAGNOSTIC_MODES,
  WINDOWS_DIRECT_RUN_MODE_NAMES,
  resolveWindowsDirectDiagnosticMode,
};
