import html
import re

from data.symbol_names import ENTITY_TO_ALIAS, SYMBOL_TO_NAME


def extract_terminators(file_content: str):
    """
    Extracts (state, output) tuples from the <terminators> block.
    """
    block = re.search(
        r"<terminators>(.*?)</terminators>", file_content, re.DOTALL
    )
    if not block:
        raise ValueError("No <terminators> block found.")
    return re.findall(
        r'<when state="([^"]+)" output="([^"]+)"\s*/>', block.group(1)
    )


def build_state_map(terminators):
    """
    Builds a mapping old_state_name -> new_state_name using create_layer_name.
    """
    state_map = {}
    for state, output in terminators:
        m = re.match(r"s(\d+)", state)
        if not m:
            continue
        num = int(m.group(1))
        new_name = create_layer_name(num, output)
        state_map[state] = new_name
    return state_map


def replace_state_references(file_content: str, state_map: dict) -> str:
    """
    Replace all state="..." references using the state_map.
    """

    def repl(match):
        state = match.group(1)
        return f'state="{state_map.get(state, state)}"'

    return re.sub(r'state="([^"]+)"', repl, file_content)


def replace_id_next_references(file_content: str, state_map: dict) -> str:
    """
    Replace all id="..." and next="..." references using the state_map.
    """
    for old, new in state_map.items():
        file_content = re.sub(
            rf'(id|next)="{re.escape(old)}"', rf'\1="{new}"', file_content
        )
    return file_content


def replace_terminators_block(file_content: str, state_map: dict) -> str:
    """
    Replace the <when state=... output=.../> lines in <terminators> with new state names.
    """

    def repl_term(match):
        old_state, output = match.groups()
        new_state = state_map.get(old_state, old_state)
        return f'<when state="{new_state}" output="{output}"/>'

    return re.sub(
        r'<when state="([^"]+)" output="([^"]+)"\s*/>', repl_term, file_content
    )


def replace_layer_names_in_file(file_content: str) -> str:
    """
    Rebuilds correct layer names from the <terminators> section and replaces them everywhere in the file.
    """
    terminators = extract_terminators(file_content)
    state_map = build_state_map(terminators)
    file_content = replace_state_references(file_content, state_map)
    file_content = replace_id_next_references(file_content, state_map)
    file_content = replace_terminators_block(file_content, state_map)
    return file_content


def create_layer_name(state_number: int, output: str) -> str:
    """
    Generate a state name of the form s{number}_{name} if output is a known symbol in SYMBOL_TO_NAME.
    Only the symbolic English name is used, never the character itself.
    """
    layer_name = f"s{state_number}"
    output = html.unescape(output)
    if output in ENTITY_TO_ALIAS:
        layer_name += ENTITY_TO_ALIAS[output]
    else:
        for char in output:
            if char in SYMBOL_TO_NAME:
                layer_name += f"_{SYMBOL_TO_NAME[char]}"
            # Otherwise, use output if it's alphanum
            elif re.fullmatch(r"[\w]+", char, re.UNICODE):
                layer_name += f"_{char}"
    return layer_name
