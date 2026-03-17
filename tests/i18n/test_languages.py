#!/usr/bin/env python3
"""
I18n Language File Tests
Tests the completeness and consistency of STEMwerk language translations.
"""

import re
from pathlib import Path


def parse_lua_language_file(file_path):
    """Parse the Lua language file and extract all language blocks with their keys."""
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Find the LANGUAGES table
    languages_match = re.search(r'LANGUAGES\s*=\s*\{(.+)\}', content, re.DOTALL)
    if not languages_match:
        return {}
    
    languages_content = languages_match.group(1)
    
    # Extract each language block (en, nl, de)
    # Match language code followed by = { ... },
    language_pattern = r'(\w+)\s*=\s*\{((?:[^{}]|\{[^}]*\})*)\}'
    languages = {}
    
    for match in re.finditer(language_pattern, languages_content):
        lang_code = match.group(1)
        lang_content = match.group(2)
        
        # Extract all keys from this language
        key_pattern = r'(\w+)\s*='
        keys = set(re.findall(key_pattern, lang_content))
        languages[lang_code] = keys
    
    return languages


def test_all_languages_present():
    """Test that all expected languages are present in the file."""
    file_path = Path(__file__).parent.parent.parent / 'i18n' / 'languages.lua'
    
    if not file_path.exists():
        print(f"✗ Language file not found: {file_path}")
        return False
    
    languages = parse_lua_language_file(file_path)
    expected_languages = {'en', 'nl', 'de'}
    
    if set(languages.keys()) >= expected_languages:
        print(f"✓ All expected languages present: {expected_languages}")
        return True
    else:
        missing = expected_languages - set(languages.keys())
        print(f"✗ Missing languages: {missing}")
        return False


def test_language_completeness():
    """Test that all languages have the same keys as English."""
    file_path = Path(__file__).parent.parent.parent / 'i18n' / 'languages.lua'
    languages = parse_lua_language_file(file_path)
    
    if 'en' not in languages:
        print("✗ English reference language not found")
        return False
    
    en_keys = languages['en']
    print(f"✓ English has {len(en_keys)} keys")
    
    all_complete = True
    for lang, keys in languages.items():
        if lang == 'en':
            continue
        
        missing = en_keys - keys
        extra = keys - en_keys
        
        if missing:
            print(f"✗ {lang.upper()} missing keys: {sorted(missing)}")
            all_complete = False
        elif extra:
            print(f"⚠ {lang.upper()} has extra keys: {sorted(extra)}")
        else:
            print(f"✓ {lang.upper()} complete ({len(keys)} keys)")
    
    return all_complete


def test_critical_keys_present():
    """Test that all critical UI keys are present in all languages."""
    critical_keys = {
        # Stem names
        'vocals', 'drums', 'bass', 'other', 'guitar', 'piano',
        # Presets
        'karaoke', 'all_stems', 'instrumental',
        # UI states
        'processing', 'cancelled',
        # Help and options
        'help', 'new_tracks', 'in_place', 'parallel', 'sequential'
    }
    
    file_path = Path(__file__).parent.parent.parent / 'i18n' / 'languages.lua'
    languages = parse_lua_language_file(file_path)
    
    all_present = True
    for lang, keys in languages.items():
        missing = critical_keys - keys
        if missing:
            print(f"✗ {lang.upper()} missing critical keys: {sorted(missing)}")
            all_present = False
        else:
            print(f"✓ {lang.upper()} has all critical keys")
    
    return all_present


def test_language_coverage():
    """Generate a coverage report showing translation completeness."""
    file_path = Path(__file__).parent.parent.parent / 'i18n' / 'languages.lua'
    languages = parse_lua_language_file(file_path)
    
    if 'en' not in languages:
        print("✗ Cannot generate coverage report without English reference")
        return False
    
    en_keys = languages['en']
    total_keys = len(en_keys)
    
    print("\n=== Language Coverage Report ===")
    print(f"{'Language':<10} {'Keys':<10} {'Coverage':<10} {'Status'}")
    print("-" * 45)
    
    for lang in sorted(languages.keys()):
        keys = languages[lang]
        key_count = len(keys)
        coverage = (key_count / total_keys * 100) if total_keys > 0 else 0
        status = "✓ Complete" if key_count >= total_keys else "✗ Incomplete"
        print(f"{lang.upper():<10} {key_count:<10} {coverage:>6.1f}%    {status}")
    
    return True


def main():
    """Run all i18n tests."""
    print("Testing STEMwerk Language Files\n")
    
    tests = [
        ("All languages present", test_all_languages_present),
        ("Language completeness", test_language_completeness),
        ("Critical keys present", test_critical_keys_present),
        ("Coverage report", test_language_coverage),
    ]
    
    results = []
    for name, test_func in tests:
        print(f"\n--- {name} ---")
        try:
            result = test_func()
            results.append(result)
        except Exception as e:
            print(f"✗ Test failed with error: {e}")
            results.append(False)
    
    print("\n" + "=" * 50)
    passed = sum(results)
    total = len(results)
    print(f"Results: {passed}/{total} tests passed")
    
    return 0 if all(results) else 1


if __name__ == '__main__':
    exit(main())
