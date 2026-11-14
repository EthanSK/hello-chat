#!/usr/bin/env python3
"""Extract the real App Intents declarations for the SwiftPM-built macOS bundle."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys


def output(*arguments: str) -> str:
    return subprocess.check_output(arguments, text=True).strip()


def main() -> None:
    app = Path(sys.argv[1]).resolve()
    work = Path(sys.argv[2]).resolve() / 'AppShortcuts.noindex'
    work.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve().parent.parent / 'Sources/AppShortcuts.swift'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    toolchain = Path(output('xcrun', '--find', 'swiftc')).resolve().parents[2]
    sdk = output('xcrun', '--sdk', 'macosx', '--show-sdk-path')
    xcode = output('xcodebuild', '-version').split('Build version ')[1]
    minimum = info['LSMinimumSystemVersion']
    target = f'arm64-apple-macos{minimum}'

    # The compiler consumes a protocol-name array. Current Xcode stores that
    # array inside a versioned descriptor; derive it from the selected toolchain.
    descriptor = json.loads((toolchain / 'usr/share/swift/SwiftConstantValues/AppIntents.json').read_bytes())
    protocols = descriptor['constValueProtocols'] if isinstance(descriptor, dict) else descriptor
    protocol_file = work / 'protocols.json'
    protocol_file.write_text(json.dumps(protocols))
    constants = work / 'HelloChat.swiftconstvalues'
    subprocess.run(['xcrun', 'swiftc', '-typecheck', '-parse-as-library', '-module-name', 'HelloChat',
                    '-target', target, '-sdk', sdk, '-Xfrontend', '-emit-const-values-path',
                    '-Xfrontend', str(constants), '-const-gather-protocols-list', str(protocol_file), str(source)], check=True)
    sources_list = work / 'sources.txt'
    sources_list.write_text(str(source) + '\n')
    constants_list = work / 'constants.txt'
    constants_list.write_text(str(constants) + '\n')
    resources = app / 'Contents/Resources'
    subprocess.run(['xcrun', 'appintentsmetadataprocessor', '--output', str(resources),
                    '--toolchain-dir', str(toolchain), '--module-name', 'HelloChat', '--sdk-root', sdk,
                    '--xcode-version', xcode, '--platform-family', 'macOS', '--deployment-target', minimum,
                    '--target-triple', target, '--source-file-list', str(sources_list),
                    '--swift-const-vals-list', str(constants_list)], check=True)
    metadata = resources / 'Metadata.appintents'
    subprocess.run(['xcrun', 'appintentsnltrainingprocessor', '--extracted-metadata-path', str(metadata),
                    '--infoplist-path', str(app / 'Contents/Info.plist'), '--temp-dir-path', str(work / 'nlu'),
                    '--bundle-id', info['CFBundleIdentifier'], '--product-path', str(resources),
                    '--archive-ssu-assets'], check=True)

    # Compiling AppIntent types alone is insufficient. Fail packaging when the
    # system cannot discover every shipped action and its preconfigured shortcut.
    data = json.loads((metadata / 'extract.actionsdata').read_bytes())
    expected = {'StartChatIntent', 'EndChatIntent', 'MuteChatMicrophoneIntent', 'UnmuteChatMicrophoneIntent',
                'SilenceChatSpeakersIntent', 'RestoreChatSpeakersIntent', 'ChatStatusIntent'}
    assert set(data['actions']) == expected, 'Missing App Intents metadata'
    assert {shortcut['actionIdentifier'] for shortcut in data['autoShortcuts']} == expected, 'Missing App Shortcuts'
    assert all(action['isDiscoverable'] and not action['openAppWhenRun'] for action in data['actions'].values())
    assert list(resources.glob('*.lproj/nlu.appintents/*')), 'Missing Siri phrase assets'


if __name__ == '__main__':
    main()
