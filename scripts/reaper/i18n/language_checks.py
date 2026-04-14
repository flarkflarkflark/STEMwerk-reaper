#!/usr/bin/env python3
"""
Test i18n language file completeness and switching.
Validates that all language keys are present in all languages.
"""
import re
from pathlib import Path
from typing import Dict, Set


def parse_lua_language_file(file_path: Path) -> Dict[str, Set[str]]:
    """Parse Lua language file and extract keys for each language."""
    content = file_path.read_text(encoding='utf-8')
    
    languages = {}
    current_lang = None
    current_keys = set()
    
    # Pattern to match language blocks: en = {, nl = {, de = {
    lang_pattern = re.compile(r'^\s*(\w+)\s*=\s*\{', re.MULTILINE)
    # Pattern to match key assignments: key = "value",
    key_pattern = re.compile(r'^\s*(\w+)\s*=\s*"', re.MULTILINE)
    
    lines = content.split('\n')
    in_language_block = False
    brace_depth = 0
    
    for line in lines:
        # Check for language block start
        lang_match = lang_pattern.match(line)
        if lang_match and brace_depth == 0:
            if current_lang:
                languages[current_lang] = current_keys
            current_lang = lang_match.group(1)
            current_keys = set()
            in_language_block = True
            brace_depth = 1
            continue
        
        if in_language_block:
            # Track brace depth
            brace_depth += line.count('{') - line.count('}')
            
            # Extract keys
            key_match = key_pattern.match(line)
            if key_match:
                current_keys.add(key_match.group(1))
            
            # End of language block
            if brace_depth == 0:
                in_language_block = False
                languages[current_lang] = current_keys
    
    return languages


def test_all_languages_present():
    """Test that en, nl, de languages are all defined."""
    lang_file = Path(__file__).parent.parent.parent / "i18n" / "languages.lua"
    
    if not lang_file.exists():
        print(f"✗ Language file not found: {lang_file}")
        return False
    
    languages = parse_lua_language_file(lang_file)
    
    expected_langs = {'en', 'nl', 'de'}
    found_langs = set(languages.keys())
    
    if expected_langs != found_langs:
        missing = expected_langs - found_langs
        extra = found_langs - expected_langs
        if missing:
            print(f"✗ Missing languages: {missing}")
        if extra:
            print(f"  Extra languages found: {extra}")
        return False
    
    print(f"✓ All expected languages present: {found_langs}")
    return True


def test_language_completeness():
    """Test that all languages have the same set of keys."""
    lang_file = Path(__file__).parent.parent.parent / "i18n" / "languages.lua"
    languages = parse_lua_language_file(lang_file)
    
    # Use English as reference
    if 'en' not in languages:
        print("✗ English (en) language not found")
        return False
    
    en_keys = languages['en']
    print(f"\n✓ English has {len(en_keys)} keys")
    
    all_complete = True
    
    for lang, keys in languages.items():
        if lang == 'en':
            continue
        
        missing = en_keys - keys
        extra = keys - en_keys
        
        if missing or extra:
            all_complete = False
            print(f"\n✗ {lang.upper()} language incomplete:")
            if missing:
                print(f"  Missing keys ({len(missing)}): {sorted(list(missing)[:10])}...")
            if extra:
                print(f"  Extra keys ({len(extra)}): {sorted(list(extra)[:10])}...")
        else:
            print(f"✓ {lang.upper()} complete ({len(keys)} keys)")
    
    return all_complete


def test_critical_keys_present():
    """Test that critical UI keys are present in all languages."""
    lang_file = Path(__file__).parent.parent.parent / "i18n" / "languages.lua"
    languages = parse_lua_language_file(lang_file)
    
    critical_keys = {
        'vocals', 'drums', 'bass', 'other', 'guitar', 'piano',
        'karaoke', 'all_stems', 'instrumental',
        'processing', 'cancelled', 'help',
        'new_tracks', 'in_place', 'parallel', 'sequential'
    }
    
    print(f"\n✓ Checking {len(critical_keys)} critical keys...")
    
    all_present = True
    for lang, keys in languages.items():
        missing = critical_keys - keys
        if missing:
            all_present = False
            print(f"✗ {lang.upper()} missing critical keys: {missing}")
        else:
            print(f"✓ {lang.upper()} has all critical keys")
    
    return all_present


def test_language_coverage():
    """Generate coverage report for all languages."""
    lang_file = Path(__file__).parent.parent.parent / "i18n" / "languages.lua"
    languages = parse_lua_language_file(lang_file)
    
    if 'en' not in languages:
        return False
    
    en_keys = languages['en']
    
    print(f"\n{'='*60}")
    print("Language Coverage Report")
    print(f"{'='*60}")
    print(f"{'Language':<15} {'Keys':<10} {'Coverage':<10} {'Status'}")
    print(f"{'-'*60}")
    
    for lang in sorted(languages.keys()):
        keys = languages[lang]
        if lang == 'en':
            coverage = 100.0
        else:
            coverage = (len(keys & en_keys) / len(en_keys)) * 100
        
        status = "✓ Complete" if coverage == 100.0 else "✗ Incomplete"
        print(f"{lang.upper():<15} {len(keys):<10} {coverage:>6.1f}%    {status}")
    
    print(f"{'='*60}\n")
    return True


def main():
    """Run all i18n tests."""
    print("\n" + "="*60)
    print("STEMwerk i18n Tests")
    print("="*60 + "\n")
    
    tests = [
        ("Languages Present", test_all_languages_present),
        ("Language Completeness", test_language_completeness),
        ("Critical Keys", test_critical_keys_present),
        ("Coverage Report", test_language_coverage)
    ]
    
    results = []
    for name, test_func in tests:
        print(f"\nRunning: {name}")
        print("-" * 40)
        result = test_func()
        results.append((name, result))
    
    # Summary
    print("\n" + "="*60)
    print("Test Summary")
    print("="*60)
    passed = sum(1 for _, result in results if result)
    total = len(results)
    
    for name, result in results:
        status = "✓ PASS" if result else "✗ FAIL"
        print(f"{status:<10} {name}")
    
    print(f"\nTotal: {passed}/{total} tests passed")
    print("="*60 + "\n")
    
    return 0 if passed == total else 1


if __name__ == "__main__":
    import sys
    sys.exit(main())