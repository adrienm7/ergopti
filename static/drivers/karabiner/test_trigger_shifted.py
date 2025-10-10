#!/usr/bin/env python3
"""Test script for is_trigger_shifted function."""

def is_trigger_shifted(trigger: str) -> bool:
    """Detect if a trigger is a 'shifted' version (uppercase equivalent).
    
    Special cases:
    - Triggers with espace insécable ( ) + punctuation are considered shifted
    - Triggers with espace fine insécable ( ) + punctuation are considered shifted
    - Normal uppercase letters are considered shifted
    """
    if not trigger:
        return False
    
    # Check for espace insécable or espace fine insécable + punctuation patterns (these are "shifted" versions)
    if len(trigger) >= 2 and trigger[0] in [' ', ' ']:  # espace insécable or espace fine insécable
        return True
    
    # Check for normal uppercase letters
    if len(trigger) > 0 and trigger[0].isupper():
        return True
        
    return False

# Tests
test_cases = [
    (',', False),        # trigger normal
    (' ;', True),       # espace insécable + ;
    (' :', True),       # espace insécable + :
    (' ?', True),       # espace fine insécable + ?
    ('A', True),        # lettre majuscule
    ('a', False),       # lettre minuscule
    ("'", False),       # apostrophe normale
]

print("Test de la fonction is_trigger_shifted:")
print("=" * 40)
for case, expected in test_cases:
    result = is_trigger_shifted(case)
    status = "✓" if result == expected else "✗"
    print(f'{status} {repr(case):10} -> {result:5} (attendu: {expected})')