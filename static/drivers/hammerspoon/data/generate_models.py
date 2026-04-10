# hammerspoon/data/generate_models.py
"""
==============================================================================
MODULE: Generate Models JSON
DESCRIPTION:
Reads a base JSON configuration of LLM models and enriches it by fetching
metadata, parameter counts, and hardware requirements from HuggingFace
and Ollama.

FEATURES & RATIONALE:
1. Automated Metadata Fetching: Scrapes tags, parameter sizes, and updates.
2. Hardware Estimation: Intelligently calculates RAM and disk requirements.
3. Failsafe Parsing: Gracefully handles network timeouts and missing data.
==============================================================================
"""

import json
import math
import os
import re
from typing import Any, Dict, Optional, Union

import requests
from bs4 import BeautifulSoup

REQUEST_TIMEOUT = 10


# ==========================================
# ==========================================
# ======= 1/ Data Fetching Utilities =======
# ==========================================
# ==========================================


def extract_repo_id(url: Optional[str]) -> Optional[str]:
    """Extracts the repository ID from a HuggingFace URL.

    Args:
            url: The full HuggingFace repository URL.

    Returns:
            The extracted repository ID or None if parsing fails.
    """
    if not url:
        return None
    if "huggingface.co/" not in url:
        return url
    return url.split("huggingface.co/")[-1].strip("/")


def determine_model_type(model_name: str) -> str:
    """Determines if a model is chat (instruct) or completion (base) based on common naming conventions.

    Args:
            model_name: The name of the model to evaluate.

    Returns:
            A string indicating the model type.
    """
    name_lower = model_name.lower()

    if re.search(r"(-base|base)$", name_lower):
        return "completion"

    if re.search(r"(-it|-instruct|-chat|chat|instruct)$", name_lower):
        return "chat"

    return "chat"


def get_hf_metadata(repo_url: Optional[str]) -> Dict[str, Any]:
    """Fetches model metadata from the HuggingFace API.

    Retrieves tags, parameter counts, last updated dates, and the raw README content.

    Args:
            repo_url: The full HuggingFace repository URL.

    Returns:
            A dictionary containing the enriched metadata.
    """
    default_meta = {
        "tags": [],
        "total_params": "N/A",
        "readme": "",
        "last_updated": "Unknown",
    }

    repo_id = extract_repo_id(repo_url)
    if not repo_id:
        return default_meta

    api_url = f"https://huggingface.co/api/models/{repo_id}"
    try:
        response = requests.get(api_url, timeout=REQUEST_TIMEOUT)
        if response.status_code != 200:
            return default_meta
        data = response.json()
    except requests.RequestException:
        return default_meta

    raw_tags = data.get("tags", [])
    target_tags = {
        "mixture_of_experts",
        "moe",
        "text-generation",
        "conversational",
        "reasoning",
        "instruct",
        "dsa",
    }
    relevant_tags = [t for t in raw_tags if t in target_tags]

    if "text-generation" in raw_tags or "conversational" in raw_tags:
        relevant_tags.append("text")
    if "moe" in raw_tags:
        relevant_tags.append("mixture_of_experts")

    total_params = "N/A"
    safetensors = data.get("safetensors", {}).get("parameters", {})
    for _, val in safetensors.items():
        if isinstance(val, int):
            billions = val / 1e9
            total_params = (
                f"{round(billions, 1) if billions % 1 != 0 else int(billions)}B"
            )
            break

    last_modified = data.get("lastModified")
    created_at = data.get("createdAt")
    date_str = last_modified or created_at
    clean_date = date_str.split("T")[0] if date_str else "Unknown"

    readme = ""
    try:
        readme_req = requests.get(
            f"https://huggingface.co/{repo_id}/raw/main/README.md",
            timeout=REQUEST_TIMEOUT,
        )
        if readme_req.status_code == 200:
            readme = readme_req.text
    except requests.RequestException:
        pass

    return {
        "tags": list(set(relevant_tags)),
        "total_params": total_params,
        "readme": readme,
        "last_updated": clean_date,
    }


# ==========================================
# ==========================================
# ======= 2/ Hardware & Math Helpers =======
# ==========================================
# ==========================================


def get_hf_repo_size_gb(repo_url: Optional[str]) -> Optional[float]:
    """Calculates the total size of a HuggingFace repository in Gigabytes.

    Args:
            repo_url: The full HuggingFace repository URL.

    Returns:
            The total size in GB, or None if the request fails.
    """
    repo_id = extract_repo_id(repo_url)
    if not repo_id:
        return None

    api_url = f"https://huggingface.co/api/models/{repo_id}/tree/main"
    try:
        response = requests.get(api_url, timeout=REQUEST_TIMEOUT)
        if response.status_code != 200:
            return None
        files = response.json()
        total_bytes = sum(
            f.get("size", 0) for f in files if isinstance(f, dict)
        )
        return round(total_bytes / (1024**3), 2)
    except requests.RequestException:
        return None


def get_ollama_size_gb(ollama_url: Optional[str]) -> Optional[float]:
    """Scrapes the model size in Gigabytes from an Ollama model page.

    Args:
            ollama_url: The full Ollama repository URL.

    Returns:
            The extracted size in GB, or None if parsing fails.
    """
    if not ollama_url or "ollama.com" not in ollama_url:
        return None

    try:
        response = requests.get(ollama_url, timeout=REQUEST_TIMEOUT)
        soup = BeautifulSoup(response.text, "html.parser")
        for span in soup.find_all("span"):
            text = span.text.strip()
            if re.match(r"^\d+(\.\d+)?\s*(GB|MB)$", text, re.IGNORECASE):
                size_matches = re.findall(r"\d+\.\d+|\d+", text)
                if size_matches:
                    size = float(size_matches[0])
                    if "MB" in text.upper():
                        size /= 1024
                    return round(size, 2)
    except Exception:
        pass

    return None


def extract_active_params(
    model_name: str, readme_text: str, total_params: str
) -> str:
    """Extracts active parameters for Mixture of Experts (MoE) or Effective parameter models.

    Prioritizes the model name to avoid conflicts when multiple models share a README.

    Args:
            model_name: The name of the model.
            readme_text: The content of the model's README file.
            total_params: The fallback total parameters string.

    Returns:
            A string representing the active parameter count.
    """
    match_a_name = re.search(r"(?i)A(\d+(?:\.\d+)?)B", model_name)
    if match_a_name:
        return f"{match_a_name.group(1)}B"

    match_e_name = re.search(r"(?i)E(\d+(?:\.\d+)?)B", model_name)
    if match_e_name:
        return f"{match_e_name.group(1)}B"

    if readme_text:
        match_active = re.search(
            r"(?i)(\d+(?:\.\d+)?B)[ -]*active", readme_text
        )
        if match_active:
            return match_active.group(1).upper()

    return total_params


def estimate_ram(download_gb: Optional[float]) -> Optional[int]:
    """Estimates the required RAM in GB.

    Uses a heuristic formula: Model weight size + ~2.5GB for KV Context Cache
    and Inference Engine overhead. Rounds up to the nearest standard hardware tier.

    Args:
            download_gb: The size of the model download in GB.

    Returns:
            The estimated required RAM tier in GB.
    """
    if not download_gb:
        return None

    tiers = [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512]
    ram_needed = download_gb + 2.5

    for tier in tiers:
        if ram_needed <= tier:
            return tier

    return math.ceil(ram_needed / 32) * 32


def calculate_hardware_requirements(download_gb: float) -> Dict[str, float]:
    """Calculates unified hardware requirements based on the download size.

    Args:
            download_gb: The size of the model download in GB.

    Returns:
            A dictionary mapping hardware components to their GB requirements.
    """
    return {
        "download_gb": round(download_gb, 2),
        "disk_gb": round(download_gb, 2),
        "ram_gb": estimate_ram(download_gb),
    }


def estimate_hardware_fallback(params_str: str) -> Dict[str, Optional[float]]:
    """Estimates hardware requirements based strictly on parameter count.

    Assumes 4-bit quantization (~0.65 GB per 1B parameters).

    Args:
            params_str: A string representing the total parameter count.

    Returns:
            A dictionary mapping hardware components to fallback estimates.
    """
    try:
        val = float(re.sub(r"[^\d.]", "", params_str))
        estimated_download_gb = val * 0.65
        return calculate_hardware_requirements(estimated_download_gb)
    except ValueError:
        return {"disk_gb": None, "download_gb": None, "ram_gb": None}


def estimate_speed(active_params_str: str) -> Dict[str, Union[int, str]]:
    """Estimates inference speed (tokens per second) based on active parameter count.

    Args:
            active_params_str: A string representing the active parameter count.

    Returns:
            A dictionary mapping speed metrics to their estimated values.
    """
    try:
        val = float(re.sub(r"[^\d.]", "", active_params_str))
    except ValueError:
        return {"speed_tok_s": 50, "speed_tier": "Unknown"}

    if val <= 4:
        return {"speed_tok_s": 80, "speed_tier": "Very Fast"}
    elif val <= 10:
        return {"speed_tok_s": 50, "speed_tier": "Fast"}
    elif val <= 35:
        return {"speed_tok_s": 25, "speed_tier": "Moderate"}
    elif val <= 75:
        return {"speed_tok_s": 10, "speed_tier": "Slow"}
    else:
        return {"speed_tok_s": 3, "speed_tier": "Very Slow"}


# ==========================================
# ==========================================
# ======= 3/ Main Generator Logic ==========
# ==========================================
# ==========================================


def build_final_json(v0_filepath: str, output_filepath: str) -> None:
    """Reads the initial JSON, processes data, and writes the enriched JSON.

    Args:
            v0_filepath: The path to the source JSON file.
            output_filepath: The path where the enriched JSON will be saved.
    """
    with open(v0_filepath, "r", encoding="utf-8") as f:
        v0_data = json.load(f)

    final_output = []

    for provider_block in v0_data:
        provider_name = provider_block.get("provider", "Unknown Provider")
        new_provider = {"label": provider_name, "families": []}

        for family_block in provider_block.get("families", []):
            family_name = family_block.get("family", "Unknown Family")
            new_family = {"label": family_name, "models": []}

            for model_item in family_block.get("models", []):
                model_name = model_item.get("name", "Unknown Model")
                print(f"Traitement en cours : {model_name}…")

                urls = model_item.get("urls", {})
                hf_meta = get_hf_metadata(urls.get("hf"))

                total_p = hf_meta["total_params"]
                active_p = extract_active_params(
                    model_name, hf_meta["readme"], total_p
                )
                speed_data = estimate_speed(active_p)
                fallback_hw = estimate_hardware_fallback(total_p)

                model_type = determine_model_type(model_name)
                hardware = {}

                mlx_url = urls.get("mlx")
                mlx_dl = get_hf_repo_size_gb(mlx_url) if mlx_url else None
                hardware["mlx"] = (
                    calculate_hardware_requirements(mlx_dl)
                    if mlx_dl
                    else fallback_hw
                )

                ollama_url = urls.get("ollama")
                ollama_dl = (
                    get_ollama_size_gb(ollama_url) if ollama_url else None
                )
                hardware["ollama"] = (
                    calculate_hardware_requirements(ollama_dl)
                    if ollama_dl
                    else fallback_hw
                )

                new_family["models"].append(
                    {
                        "name": model_name,
                        "type": model_type,
                        "last_updated": hf_meta["last_updated"],
                        "parameters": {"total": total_p, "active": active_p},
                        "capabilities": {
                            "speed_tok_s": speed_data["speed_tok_s"],
                            "speed_tier": speed_data["speed_tier"],
                            "tags": hf_meta["tags"]
                            if hf_meta["tags"]
                            else ["dense", "text"],
                        },
                        "hardware_requirements": hardware,
                        "urls": urls,
                    }
                )

            new_provider["families"].append(new_family)

        final_output.append(new_provider)

    with open(output_filepath, "w", encoding="utf-8") as f:
        json.dump(final_output, f, indent=4, ensure_ascii=False)

    print(f"\nSuccès ! Sauvegardé dans {output_filepath}")


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    v0_path = os.path.join(script_dir, "llm_models_v0.json")
    final_path = os.path.join(script_dir, "llm_models.json")

    build_final_json(v0_path, final_path)
