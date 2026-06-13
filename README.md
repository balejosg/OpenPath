# OpenPath

**Intentional internet for the classroom. Private by design. Open by conviction.**

[![CI](https://github.com/balejosg/openpath/actions/workflows/ci.yml/badge.svg)](https://github.com/balejosg/openpath/actions/workflows/ci.yml)
[![codecov](https://codecov.io/github/balejosg/openpath/graph/badge.svg)](https://app.codecov.io/github/balejosg/openpath)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)

---

## The Problem

Students get distracted on computers. Every teacher who has taught in a technology or computer science classroom knows it. **OpenPath is an open-source tool that gives teachers direct control over which websites are available in their classroom, with no telemetry, no browsing data collection, and full transparency.**

## Why Not Just Another Filter?

### No more cat and mouse

Most filters work by **blacklisting**, maintaining an ever-growing list of banned sites. This turns internet management into an exhausting game: students find a new game site, a proxy, or an unblocked social media mirror, and the teacher scrambles to block it. The next day, there is a new one. You are always one step behind.

**OpenPath flips the model.** Instead of banning what is bad, you approve what is needed. If a domain is not on the whitelist, it simply does not exist on that machine. There is no next loophole to discover, no new site to chase, because the default state is _closed_. Students cannot reach distractions because the door was never open in the first place.

### The teacher sets the rules, not IT

Commercial filters are usually managed by the IT department at a school-wide level. One global policy for every class in the building. But a biology teacher and a web development teacher have completely different needs, and a generic filter doesn't know that.

With OpenPath, **each teacher manages their own classroom's whitelist**. You decide what your students can access, and you can change it between lessons or even mid-class. IT handles the infrastructure; you handle the teaching.

### Unblock a domain in seconds, mid-class

A student needs a resource you didn't anticipate? No need to submit a ticket to IT and wait. The teacher can **add a domain to the whitelist from the dashboard and it takes effect within seconds** while the class is still running. The browser extension also lets students request an unblock that the teacher can approve on the spot. The workflow stays in the classroom, not in a helpdesk queue.

## What OpenPath Does

OpenPath puts **the teacher in control** of internet access in their classroom, not the IT department, not a remote vendor, not a global policy that tries to fit every subject at once. Each teacher defines exactly which websites are available for their class and enforces that decision at the operating system level. If a domain is not on the approved list, it simply does not resolve. No redirect pages, no tracking, no grey areas.

- **Teacher-driven, per-classroom control**: each classroom has its own whitelist, managed by the teacher who knows what the lesson needs.
- **Whitelist-based, not blacklist-based**: only explicitly approved domains open. Everything else is blocked by default.
- **Real-time flexibility**: add or remove domains mid-class from the dashboard. Students can request unblocks; teachers approve them instantly.
- **Endpoint enforcement**: agents on Linux and Windows apply policy through local DNS and firewall rules, not browser plugins alone.
- **Browser integration**: a Firefox extension shows teachers what is being blocked and lets students request access to sites they need.
- **Admin dashboard**: a clean web interface where teachers manage their classrooms, approved domains, and schedules.

## Current Limitations

OpenPath is intentionally restrictive while the endpoint and browser-control
surface is still maturing:

- The full classroom browser workflow is currently centered on managed Firefox:
  blocked-page visibility, blocked-path and blocked-subdomain enforcement, and
  student unblock requests rely on the Firefox extension and native host.
- Endpoint agents may block unmanaged or unapproved browsers to prevent students
  from bypassing local DNS and firewall policy. On Windows this includes
  denying common alternative browsers and portable browsers unless a managed
  browser path is explicitly supported.
- On Windows, the managed browser boundary uses AppLocker for standard
  non-admin student accounts. This is not a browser-only switch: it can also
  block executables or scripts launched from student-writable locations such as
  Downloads, Desktop, or Temp, and selected bypass tools such as `curl`, `ssh`,
  `winget`, `certutil`, and Windows script hosts. Classroom software should be
  inventoried and installed by IT into managed locations such as Program Files
  before enabling enforcement on real student PCs.
- Managed Chromium artifacts exist in the repository, but they should not be
  treated as equivalent full-browser support for every deployment. Use Firefox
  as the supported browser path unless the target environment has explicitly
  validated a managed Chromium or Edge flow.
- Enforcement is applied at the host operating-system layer (local resolver,
  host firewall, and AppLocker). A virtual machine running on a managed host is a
  separate operating system with its own network stack and is not automatically
  subject to the host policy. A VM in NAT mode egresses through the host stack and
  is covered by the host's default-deny DNS firewall; a bridged VM is a peer on the
  physical LAN and is not visible to the host at all. On Windows the agent can
  optionally neutralize bridged networking for VirtualBox/VMware by unbinding their
  bridge filter drivers (`blockBridgedAdapters`), which leaves the VM working in NAT
  while preventing the unfiltered bridged path. Hyper-V external switches are out of
  scope for this control and must be restricted by policy (do not grant Hyper-V
  Administrators or pre-create an external switch). For deployments where students
  can run VMs, pair the endpoint agent with network-layer enforcement (a sanctioned
  resolver pinned by DHCP, gateway egress filtering, and switch port-security or
  802.1X) so that any device on the LAN (host or guest) is filtered uniformly.

## Privacy First, Not as a Feature, but as Architecture

OpenPath was built from the ground up so that **student computers never share browsing data** with anyone. This is not a setting you can toggle; it is how the system works:

| Promise                                   | How it's enforced                                                                                                                                                                                                          |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **No telemetry**                          | The agents and browser extension send zero analytics or usage data to any third party. There are no tracking pixels, no beacons, no "anonymous" usage metrics.                                                             |
| **No browsing history leaves the device** | The enforcement is local: DNS resolution and firewall rules run on the student's own machine. The central server knows the policy, not what each student tried to visit.                                                   |
| **No data monetisation**                  | OpenPath is AGPL-3.0 licensed. There is no commercial entity harvesting data behind the scenes.                                                                                                                            |
| **Local-only browser state**              | The browser extension keeps blocked-resource information in local runtime memory. It does not upload browsing activity.                                                                                                    |
| **Native messaging stays on-machine**     | When the extension communicates with the system agent, that conversation never leaves localhost.                                                                                                                           |
| **Auditable by design**                   | Every line of enforcement logic, agents, extension, and API, is in this repository under an open-source license. No hidden binaries, no obfuscated cloud rules. You can read exactly what runs on your students' machines. |

You can verify every one of these claims yourself: the entire codebase is here, in this repository. That is the point.

> **Read the full extension privacy policy:** [`firefox-extension/PRIVACY.md`](firefox-extension/PRIVACY.md)

## How It Works

```
+-------------------------------------------------+
|              OpenPath Server                    |
|  +----------+  +-----------+  +--------------+  |
|  | API      |  | Admin SPA |  | PostgreSQL   |  |
|  | (tRPC)   |  | (React)   |  |              |  |
|  +----+-----+  +-----------+  +--------------+  |
|       |  Policy updates (SSE / scheduled)       |
+-------+-----------------------------------------+
        |
        v
+-----------------------+   +-----------------------+
|  Linux Agent          |   |  Windows Agent         |
|  dnsmasq + iptables   |   |  Acrylic DNS + FW      |
|  local enforcement    |   |  local enforcement     |
+-----------+-----------+   +-----------+-----------+
            |                           |
            v                           v
     +-------------+             +-------------+
     |  Browser    |             |  Browser    |
     |  Extension  |             |  Extension  |
     |  (local UI) |             |  (local UI) |
     +-------------+             +-------------+
```

1. Each teacher defines approved domains for their classroom through the admin dashboard. IT sets up the infrastructure; teachers set the rules.
2. Endpoint agents pull the policy and configure local DNS and firewall rules.
3. The browser extension provides real-time visibility into what is blocked and lets users request unblocks.
4. **All enforcement is local.** The server distributes policy; it does not inspect traffic.

## What Ships Today

| Package                                             | Purpose                                                                                |
| --------------------------------------------------- | -------------------------------------------------------------------------------------- |
| [`api/`](api/README.md)                             | Express + tRPC service, setup flow, agent delivery, and public request endpoints       |
| [`react-spa/`](react-spa/README.md)                 | Administration UI for managing classrooms, domains, and policy                         |
| [`linux/`](linux/README.md)                         | Debian/Ubuntu agent: dnsmasq, iptables, SSE updates, self-update                       |
| [`windows/`](windows/README.md)                     | PowerShell agent: Acrylic DNS Proxy, Windows Firewall, scheduled tasks, browser policy |
| [`firefox-extension/`](firefox-extension/README.md) | Browser extension with managed distribution for Firefox and Chromium                   |
| [`shared/`](shared/README.md)                       | Shared schemas, domain helpers, validation, and role definitions                       |
| [`dashboard/`](dashboard/README.md)                 | Compatibility layer bridging legacy REST flows to the tRPC API                         |

## Getting Started

### Prerequisites

- Node.js >= 20
- PostgreSQL
- npm workspaces

### Quick start

```bash
# Clone and install
git clone https://github.com/balejosg/openpath.git
cd openpath
npm install
npm run build --workspaces --if-present

# Start the API and admin UI
npm run dev --workspace=@openpath/api
npm run dev --workspace=@openpath/react-spa
```

For endpoint agents, see the platform-specific guides:

- **Linux:** [`linux/README.md`](linux/README.md)
- **Windows:** [`windows/README.md`](windows/README.md)

### Evaluation resources

| If you need...                    | Start here                                                                                     |
| --------------------------------- | ---------------------------------------------------------------------------------------------- |
| Self-hosting prerequisites        | [`docs/evaluation/self-hosted-prerequisites.md`](docs/evaluation/self-hosted-prerequisites.md) |
| Deployment topologies             | [`docs/evaluation/deployment-shapes.md`](docs/evaluation/deployment-shapes.md)                 |
| Adoption and ownership boundaries | [`docs/evaluation/adoption-path.md`](docs/evaluation/adoption-path.md)                         |
| Architecture decisions            | [`docs/ADR.md`](docs/ADR.md)                                                                   |
| Project roadmap                   | [`ROADMAP.md`](ROADMAP.md)                                                                     |
| Security hardening                | [`docs/SECURITY-HARDENING.md`](docs/SECURITY-HARDENING.md)                                     |
| Full documentation map            | [`docs/INDEX.md`](docs/INDEX.md)                                                               |

## Help Us Fix This Problem

Distractions in computer classrooms are a real, everyday problem for thousands of teachers. Commercial solutions are often expensive, privacy-invasive, or both. OpenPath exists because we believe there should be a transparent, auditable, privacy-respecting alternative, and **we need help building it**.

### Ways to contribute

- **Report bugs** - Found something broken? [Open an issue](https://github.com/balejosg/openpath/issues).
- **Suggest features** - Have an idea that would help your classroom? Open a feature request or classroom feedback issue.
- **Submit code** - Pick up an open issue, fix a bug, or improve a feature. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow.
- **Improve docs** - Clearer documentation helps more schools adopt the project.
- **Test in your school** - Real-world feedback from teachers and IT teams is invaluable.
- **Translate** - Help make OpenPath accessible to schools in your language.
- **Spread the word** - Tell a colleague, write about it, or present it at your next tech meeting.

### You don't need to be a developer

If you work in education and you understand the distraction problem, your perspective matters. Design feedback, workflow suggestions, and "this doesn't make sense in a real classroom" reports are just as valuable as pull requests.

Start with [`ROADMAP.md`](ROADMAP.md) to see where help is useful now, and use
the GitHub issue templates to share classroom feedback, deployment blockers, or
small contribution ideas.

### Developer quick reference

```bash
# Verify your changes
npm run verify:quick          # Typecheck + lint + format
npm run verify:agent          # Agent-level checks

# Run tests
npm run test:api
npm run test:react-spa
npm test --workspace=@openpath/firefox-extension
```

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) for conventions, commit format, and PR workflow.

## Trust, Security, and Auditing

- **Security disclosure policy:** [`SECURITY.md`](SECURITY.md)
- **Vulnerability reports:** Do not open public issues. Use a [GitHub private security advisory](https://github.com/balejosg/openpath/security/advisories) or contact the maintainers directly.
- **Operator hardening checklist:** [`docs/SECURITY-HARDENING.md`](docs/SECURITY-HARDENING.md)
- **Browser extension privacy posture:** [`firefox-extension/PRIVACY.md`](firefox-extension/PRIVACY.md)
- **Public integration boundary:** [`docs/adr/0010-public-spa-extension-surface.md`](docs/adr/0010-public-spa-extension-surface.md)

## License

OpenPath is free software licensed under [`AGPL-3.0-or-later`](LICENSE).

This means you can use, study, modify, and redistribute it, as long as you share your changes under the same terms. If you run a modified version as a network service, the AGPL requires you to make the source available to its users.

See [`LICENSING.md`](LICENSING.md) for details.

> **Note:** Maintained documentation is English-only. The full documentation map lives in [`docs/INDEX.md`](docs/INDEX.md).

---

<p align="center">
  <em>Built for classrooms that respect both focus and privacy.</em>
</p>
