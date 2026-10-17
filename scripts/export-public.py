"""Create a source-only publication snapshot without copying private development history."""
from pathlib import Path
import shutil
ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / '.publish' / 'Knock'
DEST.mkdir(parents=True, exist_ok=True)
for name in ('source', 'vendor', 'scripts', 'examples', 'docs', '.github'):
    shutil.copytree(ROOT / name, DEST / name, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '*.env', '*.key', '*.pem', '.DS_Store'))
for name in ('README.md', 'THIRD_PARTY_NOTICES.md', '.gitignore'):
    shutil.copy2(ROOT / name, DEST / name)
tests = DEST / 'tests'
tests.mkdir(exist_ok=True)
suites = ['portability', 'core', 'app-preferences', 'speech-models', 'library', 'voice-animation', 'gateway-retry', 'voice-model']
fixtures = ['PortabilityTests.swift', 'CoreTests.swift', 'AppPreferencesTests.swift', 'SpeechModelStoreTests.swift',
            'LibraryStoreTests.swift', 'VoiceAnimationTests.swift', 'GatewayRetryTests.swift', 'VoiceModelTests.swift', 'FaultTransport.swift', 'test-model-downloads.py']
for name in [f'test-{suite}.sh' for suite in suites] + fixtures:
    shutil.copy2(ROOT / 'tests' / name, tests / name)
print(DEST)
