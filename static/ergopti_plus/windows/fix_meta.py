import os
import re

tests_dir = r"D:\Documents\GitHub\ergopti\static\ergopti_plus\windows\tests\meta"

for filename in os.listdir(tests_dir):
    if not filename.endswith(".ahk"):
        continue
    filepath = os.path.join(tests_dir, filename)
    with open(filepath, "r", encoding="utf-8-sig") as f:
        content = f.read()

    new_content = content
    pattern1 = r'End\s*:=\s*InStr\(Rest,\s*"`n\}"\)\s*\n\s*if\s*End\s*\n\s*Rest\s*:=\s*SubStr\(Rest,\s*1,\s*End\s*\+\s*1\)'
    replacement1 = 'if RegExMatch(Rest, "m)^\\\\}", &Match)\\n\\t\\tRest := SubStr(Rest, 1, Match.Pos)'
    
    new_content = re.sub(pattern1, replacement1, new_content, flags=re.MULTILINE)

    if new_content != content:
        with open(filepath, "w", encoding="utf-8-sig", newline="") as f:
            f.write(new_content)
        print(f"Fixed {filename}")
