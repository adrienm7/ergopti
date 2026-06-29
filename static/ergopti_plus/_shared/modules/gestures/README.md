# gestures (shared data)

## Purpose

Catalogue of all gesture action identifiers (`actions.toml`) that can be assigned to gesture slots. Both drivers consume this file to populate the action picker UI and to validate slot assignments. The `sg_order` array in `actions.toml` defines the display order and group headings shown in the picker.

## Key files

| File          | Description                                                                |
| ------------- | -------------------------------------------------------------------------- |
| `actions.toml`| Ordered list of action entries with id, label key, and group parent keys    |

## Usage

The file is read at boot by both drivers; changes require a driver reload to take effect. To add a new action: add an entry to `actions.toml` **and** implement the corresponding handler in `windows/modules/gestures/init.ahk` and `macos/modules/gestures/actions.lua`.
