"""Create a source-only publication snapshot without copying private development history."""
from pathlib import Path
import shutil
ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / '.publish' / 'Hello'
DEST.mkdir(parents=True, exist_ok=True)
for name in ('source', 'vendor', 'scripts', 'examples', 'docs', '.github'):
    shutil.copytree(ROOT / name, DEST / name, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('__pycache__', 'node_modules', '*.pyc', '*.env', '*.key', '*.pem', 'memory.md', 'memory-export-*.md', '*.sqlite*', 'MigrationBackups', '.DS_Store', 'AGENT_LONG_TASK_TEST_*.md'))
for name in ('README.md', 'THIRD_PARTY_NOTICES.md', '.gitignore'):
    shutil.copy2(ROOT / name, DEST / name)
tests = DEST / 'tests'
tests.mkdir(exist_ok=True)
suites = ['portability', 'core', 'app-preferences', 'speech-models', 'library', 'voice-animation', 'gateway-retry', 'memory', 'voice-model', 'markdown', 'agent', 'database', 'sidebar-hover', 'token-usage']
fixtures = ['PortabilityTests.swift', 'CoreTests.swift', 'AppPreferencesTests.swift', 'SpeechModelStoreTests.swift',
            'LibraryStoreTests.swift', 'VoiceAnimationTests.swift', 'MemoryTests.swift', 'GatewayRetryTests.swift', 'VoiceModelTests.swift', 'FaultTransport.swift', 'test-model-downloads.py',
            'MarkdownTests.swift', 'AgentTests.swift', 'agent-native-fixture.mjs', 'agent-runtime.test.mjs', 'agent-deepseek-smoke.mjs',
            'DatabaseMigrationTests.swift', 'NavigationPerformanceTests.swift', 'AgentProgressTests.swift', 'AgentNavigationTests.swift', 'HUDIntegrationTests.swift', 'test-hud-integration.sh', 'StartupResponsivenessTests.swift', 'ContextStartupTests.swift', 'GatewayWarmupTests.swift', 'ProcessingTimingTests.swift']
fixtures += ['SidebarHoverTests.swift', 'TokenUsageTests.swift']
for name in [f'test-{suite}.sh' for suite in suites] + fixtures:
    shutil.copy2(ROOT / 'tests' / name, tests / name)
print(DEST)
