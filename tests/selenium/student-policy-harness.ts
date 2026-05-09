import { StudentPolicyServerClient } from './student-policy-client';
import { StudentPolicyDriver } from './student-policy-driver';
import {
  getDiagnosticsDir,
  getPolicyMode,
  getStudentPolicyCoverageProfile,
  getStudentPolicyScenarioGroup,
  loadScenarioFromEnv,
  optionalEnv,
} from './student-policy-env';
import {
  runAjaxAutoAllowScenarios,
  runExemptionAndScheduleScenarios,
  runFallbackPropagationProbe,
  runPathBlockingScenarios,
  runRequestLifecycleScenarios,
  runStudentPolicyMatrix,
  runStudentPolicyMatrixPhaseTwo,
  writeStudentPolicyScenarioTimings,
} from './student-policy-scenarios';
import type {
  PolicyMode,
  RunResult,
  StudentPolicyCoverageProfile,
  StudentPolicyDriverOptions,
  StudentPolicyScenarioGroup,
} from './student-policy-types';

type StudentPolicySuite =
  | 'matrix'
  | 'matrix-phase-two'
  | 'fallback-propagation'
  | 'request-lifecycle'
  | 'ajax-auto-allow'
  | 'path-blocking'
  | 'exemptions';

interface StudentPolicyPhasePlan {
  name: string;
  suite: StudentPolicySuite;
  useBrowser: boolean;
}

export function getStudentPolicyPhasePlan(
  mode: PolicyMode,
  coverageProfile: StudentPolicyCoverageProfile,
  scenarioGroup: StudentPolicyScenarioGroup = 'full'
): StudentPolicyPhasePlan[] {
  if (coverageProfile === 'fallback-propagation') {
    if (mode !== 'fallback') {
      throw new Error('The fallback-propagation coverage profile requires fallback mode');
    }

    return [{ name: 'fallback-propagation', suite: 'fallback-propagation', useBrowser: true }];
  }

  if (scenarioGroup !== 'full') {
    return [
      { name: scenarioGroup, suite: scenarioGroup, useBrowser: scenarioGroup !== 'exemptions' },
    ];
  }

  return [
    { name: 'phase-one', suite: 'matrix', useBrowser: true },
    { name: 'phase-two', suite: 'matrix-phase-two', useBrowser: false },
  ];
}

export async function runStudentPolicySuite(
  options: StudentPolicyDriverOptions = {}
): Promise<RunResult> {
  const scenario = await loadScenarioFromEnv();
  const client = new StudentPolicyServerClient(scenario);
  const mode = getPolicyMode();
  const coverageProfile = getStudentPolicyCoverageProfile();
  const scenarioGroup = getStudentPolicyScenarioGroup();
  const diagnosticsDir =
    options.diagnosticsDir ??
    optionalEnv('OPENPATH_STUDENT_DIAGNOSTICS_DIR') ??
    getDiagnosticsDir();

  const runPhase = async (
    phaseName: string,
    runner: (driver: StudentPolicyDriver) => Promise<void>,
    phaseOptions: { useBrowser?: boolean } = {}
  ): Promise<void> => {
    const driver = new StudentPolicyDriver(scenario, {
      ...options,
      diagnosticsDir,
    });

    try {
      if (phaseOptions.useBrowser !== false) {
        await driver.setup();
      }
      if (mode === 'fallback') {
        await driver.withSseDisabled(async () => {
          await runner(driver);
        });
      } else {
        await runner(driver);
      }
    } catch (error) {
      try {
        await driver.saveDiagnostics(`student-policy-${phaseName}-failure`);
      } catch {
        // Best effort diagnostics.
      }
      throw error;
    } finally {
      await driver.teardown();
    }
  };

  try {
    for (const phase of getStudentPolicyPhasePlan(mode, coverageProfile, scenarioGroup)) {
      await runPhase(
        phase.name,
        async (driver) => {
          if (phase.suite === 'matrix') {
            await runStudentPolicyMatrix(client, driver, mode);
            return;
          }

          if (phase.suite === 'matrix-phase-two') {
            await runStudentPolicyMatrixPhaseTwo(client, driver, mode);
            return;
          }

          if (phase.suite === 'fallback-propagation') {
            await runFallbackPropagationProbe(client, driver, mode);
            return;
          }

          if (phase.suite === 'request-lifecycle') {
            await runRequestLifecycleScenarios(client, driver, mode);
            return;
          }

          if (phase.suite === 'ajax-auto-allow') {
            await runAjaxAutoAllowScenarios(client, driver, mode);
            return;
          }

          if (phase.suite === 'path-blocking') {
            await runPathBlockingScenarios(client, driver, mode);
            return;
          }

          await runExemptionAndScheduleScenarios(client, driver, mode);
        },
        { useBrowser: phase.useBrowser }
      );
    }
  } finally {
    writeStudentPolicyScenarioTimings(diagnosticsDir);
  }

  return { success: true, diagnosticsDir };
}
