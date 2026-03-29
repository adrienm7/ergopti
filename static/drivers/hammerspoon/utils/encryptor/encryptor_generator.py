# hammerspoon/utils/encryptor/encryptor_generator.py

"""
==============================================================================
MODULE: Universal Encryptor App Generator
DESCRIPTION:
Generates a standalone macOS AppleScript Application (.app) to handle the
encryption and decryption of keylogger logs using the Mac's hardware serial.

FEATURES & RATIONALE:
1. File Separation: Reads logic from a dedicated .applescript file to preserve
   syntax highlighting and modularity.
2. Clean Compilation: Safely removes any existing application bundle before
   compiling to ensure no old assets or corrupted plists remain.
3. System Integration: Patches the Info.plist with CFBundleDocumentTypes to
   claim ownership over .enc files, enabling double-click decryption.
==============================================================================
"""

import os
import shutil
import subprocess

# =====================================
# =====================================
# ======= 1/ Generator Routine ========
# =====================================
# =====================================


def generate_encryptor_app(target_dir: str) -> None:
    """Generates the macOS Encryptor Application from the AppleScript source.

    Args:
            target_dir: The directory containing the .applescript and where the .app will be built.
    """
    app_path = os.path.join(target_dir, "Encryptor.app")
    script_path = os.path.join(target_dir, "encryptor.applescript")

    # Verify source script exists before attempting compilation
    if not os.path.exists(script_path):
        print(f"Erreur : Le fichier source {script_path} est introuvable.")
        return

    # Erase old app bundle to ensure a clean compilation without artifacts
    if os.path.exists(app_path):
        try:
            shutil.rmtree(app_path)
        except Exception as execution_error:
            print(
                f"Erreur lors de la suppression de l’ancienne application : {execution_error}"
            )
            return

    try:
        # Compile the app bundle using native Apple osacompile
        subprocess.run(["osacompile", "-o", app_path, script_path], check=True)

        # =================================
        # ===== 1.1) Registry Injection ===
        # =================================

        # Inject the file association logic into Info.plist to capture double-clicks on .enc files
        plist_path = os.path.join(app_path, "Contents", "Info.plist")

        # We define a document type dictionary to register .enc in macOS LaunchServices
        array_xml = """
		<array>
			<dict>
				<key>CFBundleTypeExtensions</key>
				<array><string>enc</string></array>
				<key>CFBundleTypeName</key>
				<string>Encrypted Log File</string>
				<key>CFBundleTypeRole</key>
				<string>Viewer</string>
				<key>LSHandlerRank</key>
				<string>Owner</string>
			</dict>
		</array>
		"""

        subprocess.run(
            [
                "plutil",
                "-replace",
                "CFBundleDocumentTypes",
                "-xml",
                array_xml,
                plist_path,
            ],
            check=True,
        )

        # Register the fresh app with LaunchServices so macOS immediately recognizes the .enc handler
        launch_services_tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        subprocess.run([launch_services_tool, "-f", app_path], check=True)

        print(f"Succès : Encryptor.app a été générée dans {target_dir}")

    except subprocess.CalledProcessError as sub_error:
        print(f"Erreur lors de la génération : {sub_error}")


if __name__ == "__main__":
    # Execute generation in the script's local directory natively
    current_directory = os.path.abspath(os.path.dirname(__file__))
    generate_encryptor_app(current_directory)
