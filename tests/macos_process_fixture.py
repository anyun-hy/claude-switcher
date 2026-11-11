"""Replace only the macOS kernel-process boundary in an isolated script copy."""
import re


def shell_function(source, name):
    pattern = rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}"
    match = re.search(pattern, source)
    if match is None:
        raise AssertionError(f"missing shell function {name}")
    return match.group(0)


def with_process_paths(source, body='cat "$TEST_PROCESS_PATHS"'):
    original = shell_function(source, "macos_process_paths")
    return source.replace(original, "macos_process_paths() {\n" + body + "\n}", 1)
