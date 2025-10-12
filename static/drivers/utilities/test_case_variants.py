#!/usr/bin/env python3
"""
Test script for the case variants generation functions.
"""

from mappings_functions import (
    apply_case_to_replacement_text,
    generate_case_variants_for_trigger_replacement,
)


def test_case_variants():
    """Test the case variants generation."""
    print("Testing case variants generation...")

    # Test simple word
    variants = generate_case_variants_for_trigger_replacement(
        "hello", "bonjour"
    )
    print(f"'hello' -> 'bonjour': {variants}")

    # Test single character
    variants = generate_case_variants_for_trigger_replacement("a", "à")
    print(f"'a' -> 'à': {variants}")

    # Test with symbol
    variants = generate_case_variants_for_trigger_replacement(
        "citroen", "citroën"
    )
    print(f"'citroen' -> 'citroën': {variants}")

    # Test special characters
    variants = generate_case_variants_for_trigger_replacement("don't", "do not")
    print(f"'don't' -> 'do not': {variants}")

    # Test with comma
    variants = generate_case_variants_for_trigger_replacement("yes,", "oui")
    print(f"'yes,' -> 'oui': {variants}")

    # Test 2-character trigger for mixed case
    variants = generate_case_variants_for_trigger_replacement("hc", "wh")
    print(f"'hc' -> 'wh': {variants}")

    # Test 2-character trigger for mixed case
    variants = generate_case_variants_for_trigger_replacement("ab", "cd")
    print(f"'ab' -> 'cd': {variants}")

    # Test specific case with apostrophe
    variants = generate_case_variants_for_trigger_replacement("p'", "ct")
    print(f"'p'' -> 'ct': {variants}")

    # Test specific case with uppercase apostrophe
    variants = generate_case_variants_for_trigger_replacement("P'", "ct")
    print(f"'P'' -> 'ct': {variants}")


def test_apply_case():
    """Test the apply case function."""
    print("\nTesting apply case function...")

    # Test lowercase trigger
    result = apply_case_to_replacement_text("hello", "bonjour")
    print(f"lowercase 'hello' + 'bonjour' = '{result}'")

    # Test title case trigger
    result = apply_case_to_replacement_text("Hello", "bonjour")
    print(f"title 'Hello' + 'bonjour' = '{result}'")

    # Test uppercase trigger
    result = apply_case_to_replacement_text("HELLO", "bonjour")
    print(f"uppercase 'HELLO' + 'bonjour' = '{result}'")

    # Test single character uppercase
    result = apply_case_to_replacement_text("A", "à")
    print(f"single char uppercase 'A' + 'à' = '{result}'")


if __name__ == "__main__":
    test_case_variants()
    test_apply_case()
