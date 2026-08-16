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


def extract_language_block(file_path, lang_code):
    content = Path(file_path).read_text(encoding="utf-8")
    match = re.search(rf"\b{re.escape(lang_code)}\s*=\s*\{{(.*?)\n\s*\}}", content, re.DOTALL)
    return match.group(1) if match else ""


def extract_string_value(block, key):
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*\"([^\"]*)\"", block, re.MULTILINE)
    return match.group(1) if match else None


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


def test_progress_ui_labels_are_present_in_shipped_and_canonical_i18n():
    expected = {
        "en": {
            "progress_stage_processing": "Processing",
            "progress_stage_loading_model": "Loading model",
            "progress_stage_loading_ai_model": "Loading model",
            "progress_stage_starting_separation": "Starting separation",
            "progress_stage_writing_stems": "Writing stems",
            "progress_stage_complete": "Complete",
            "progress_cancel_button": "Cancel",
            "progress_cancel_tooltip": "Cancel separation",
            "progress_cancelled_status": "Cancelled",
            "tooltip_cancel_processing": "Cancel separation",
        },
        "nl": {
            "progress_stage_processing": "Verwerken",
            "progress_stage_loading_model": "Model laden",
            "progress_stage_loading_ai_model": "Model laden",
            "progress_stage_starting_separation": "Separatie starten",
            "progress_stage_writing_stems": "Stems schrijven",
            "progress_stage_complete": "Voltooid",
            "progress_cancel_button": "Annuleren",
            "progress_cancel_tooltip": "Scheiding annuleren",
            "progress_cancelled_status": "Geannuleerd",
            "tooltip_cancel_processing": "Scheiding annuleren",
        },
        "de": {
            "progress_stage_processing": "Verarbeiten",
            "progress_stage_loading_model": "Modell laden",
            "progress_stage_loading_ai_model": "Modell laden",
            "progress_stage_starting_separation": "Trennung starten",
            "progress_stage_writing_stems": "Stems schreiben",
            "progress_stage_complete": "Abgeschlossen",
            "progress_cancel_button": "Abbrechen",
            "progress_cancel_tooltip": "Trennung abbrechen",
            "progress_cancelled_status": "Abgebrochen",
            "tooltip_cancel_processing": "Trennung abbrechen",
        },
    }
    files = [
        Path(__file__).parent.parent.parent / "i18n" / "languages.lua",
        Path(__file__).parent.parent.parent / "scripts" / "reaper" / "i18n" / "languages.lua",
    ]

    for file_path in files:
        for lang_code, expected_values in expected.items():
            block = extract_language_block(file_path, lang_code)
            assert block, f"Missing language block {lang_code!r} in {file_path}"
            for key, value in expected_values.items():
                assert extract_string_value(block, key) == value, (
                    f"{file_path} {lang_code}.{key} drifted from expected progress UI label"
                )


def test_language_tooltip_includes_right_click_hint_in_all_locales():
    # Semantic contract per locale: the tooltip must communicate both that it
    # changes the language and that right-click toggles tooltips. Exact
    # phrasing may evolve, so we assert on the localized vocabulary for each
    # concept rather than pinning a single frozen sentence.
    expected_semantics = {
        "en": {"language_change": "language", "right_click": "right-click"},
        "nl": {"language_change": "taal", "right_click": "rechtsklik"},
        "de": {"language_change": "sprache", "right_click": "rechtsklick"},
    }
    files = [
        Path(__file__).parent.parent.parent / "i18n" / "languages.lua",
        Path(__file__).parent.parent.parent / "scripts" / "reaper" / "i18n" / "languages.lua",
    ]
    keys = ("tooltip_lang", "tooltip_change_language")

    for file_path in files:
        for lang_code, markers in expected_semantics.items():
            block = extract_language_block(file_path, lang_code)
            assert block, f"Missing language block {lang_code!r} in {file_path}"
            for key in keys:
                value = extract_string_value(block, key)
                assert value, f"{file_path} {lang_code}.{key} is missing"
                lowered = value.lower()
                assert markers["language_change"] in lowered, (
                    f"{file_path} {lang_code}.{key} missing language-change hint: {value!r}"
                )
                assert markers["right_click"] in lowered, (
                    f"{file_path} {lang_code}.{key} missing right-click hint: {value!r}"
                )


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
