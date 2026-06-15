import sys
files = [
    r"D:\Documents\GitHub\ergopti\static\ergopti_plus\windows\lib\hotstrings\hotstring_engine.ahk",
    r"D:\Documents\GitHub\ergopti\static\ergopti_plus\windows\lib\hotstrings\hotstring_engine_main.ahk",
    r"D:\Documents\GitHub\ergopti\static\ergopti_plus\windows\modules\layout.ahk"
]

for filepath in files:
    with open(filepath, "r", encoding="utf-8-sig") as f:
        content = f.read()
    
    # Remove lines matching exactly `        global KLHook\n`
    new_content = "\n".join([line for line in content.split("\n") if line.strip() != "global KLHook"])
    
    if new_content != content:
        with open(filepath, "w", encoding="utf-8-sig", newline="") as f:
            f.write(new_content)
        print(f"Fixed {filepath}")
