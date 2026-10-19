#!/usr/bin/env python3
"""Offline editor contract checked by Python's independent TOML parser (3.11+)."""
import json
from pathlib import Path
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    ('"notify" = ["/tmp/fixture/third-party"]\n', True),
    ("'notify' = ['/tmp/fixture/third-party']\n", True),
    ('features.codex_hooks = false\n', True),
    ('[features]\n"codex_hooks" = false\n', True),
    ('["features"]\ncodex_hooks = false\n', True),
    ('features = { codex_hooks = false }\n', True),
    ('features = false\n', True),
    ('features = [\n  { codex_hooks = false }\n]\n', True),
    ('[features.codex_hooks]\nother = true\n', True),
    ('notify = ["/tmp/fixture/third-party"]\n', False),
    ('[features]\ncodex_hooks = false\n', False),
    ('model = "fixture-model"\n', False),
    ('[projects."/tmp/fixture-project"]\ntrust_level = "trusted"\n', False),
]
for text, _ in CASES:
    tomllib.loads(text)
with tempfile.TemporaryDirectory(prefix='ccsb-toml-') as temporary:
    directory = Path(temporary)
    encoded = json.dumps([text for text, _ in CASES])
    # JSON string encoding is valid Swift for these ASCII fixtures.
    literal = json.dumps(encoded)
    (directory / 'main.swift').write_text('''import Foundation
let inputs = try JSONSerialization.jsonObject(with: Data(INPUT.utf8)) as! [String]
let results = inputs.map { original -> [String: Any] in
    do {
        let notify = try CodexConfigEditor.ensuringRootNotify(in: original, scriptPath: "/tmp/fixture/ccsb-notify.py")
        let hooks = try CodexConfigEditor.ensuringHooksFeatureFlag(in: notify.content)
        return ["content": hooks.content, "unsupported": false,
                "consistent": CodexConfigEditor.isConsistent(hooks.content)]
    } catch CodexConfigEditor.EditError.unsupported {
        return ["content": original, "unsupported": true]
    } catch { fatalError("Unexpected editor error") }
}
let output = try JSONSerialization.data(withJSONObject: results)
print(String(data: output, encoding: .utf8)!)
'''.replace('INPUT', literal))
    binary = directory / 'probe'
    subprocess.run(['swiftc', str(ROOT / 'Sources/CCStatusBarLib/Services/CodexConfigEditor.swift'),
                    str(directory / 'main.swift'), '-o', str(binary)], check=True)
    results = json.loads(subprocess.check_output([str(binary)], text=True))
    for (original, unsupported), result in zip(CASES, results, strict=True):
        assert result['unsupported'] == unsupported, original
        parsed = tomllib.loads(result['content'])
        if unsupported:
            assert result['content'] == original
        else:
            assert result['consistent']
            before = tomllib.loads(original)
            if 'notify' in before:
                assert parsed['notify'] == before['notify']
            if before.get('features', {}).get('codex_hooks') is False:
                assert parsed['features']['codex_hooks'] is False
            if 'model' in before:
                assert parsed['model'] == before['model']
print(f'PASS: {len(CASES)} independent TOML fixtures; unsupported inputs unchanged')
