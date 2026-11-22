"""Enable APNs signing only when the selected App Store profile supports it."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def main():
    export, bundle_id = Path(sys.argv[1]), sys.argv[2]
    selected = plistlib.loads(export.read_bytes()).get("provisioningProfiles", {}).get(bundle_id)
    roots = (Path.home() / "Library/MobileDevice/Provisioning Profiles",
             Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles")
    for root in roots:
        for path in root.glob("*.mobileprovision"):
            decoded = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
            if decoded.returncode != 0:
                continue
            value = plistlib.loads(decoded.stdout)
            entitlements = value.get("Entitlements", {})
            if not entitlements.get("application-identifier", "").endswith("." + bundle_id):
                continue
            if selected not in {value.get("Name"), value.get("UUID")}:
                continue
            if entitlements.get("aps-environment") == "production":
                project = Path(__file__).with_name("Runner.xcodeproj") / "project.pbxproj"
                source = project.read_text(encoding="utf-8")
                source, count = re.subn(
                    r'(?m)^([ \t]*)GXTODO_APNS_ENVIRONMENT = "?disabled"?;',
                    r"\1CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\n\1GXTODO_APNS_ENVIRONMENT = production;",
                    source)
                if count != 3:
                    sys.exit("Could not identify the Runner configurations for APNs signing.")
                project.write_text(source, encoding="utf-8")
                print("App Store profile includes production APNs.")
            else:
                print("App Store profile has no APNs entitlement; remote notifications are unavailable in this build.")
            return
    sys.exit("Could not match the App Store provisioning profile for the Todo app.")


if __name__ == "__main__":
    main()
