"""Write an Xcode override when the active App Store profile lacks APNs."""
import plistlib
import subprocess
import sys
from pathlib import Path


def main():
    export, output, bundle_id = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
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
                output.write_text("", encoding="utf-8")
                print("App Store profile includes production APNs.")
            else:
                output.write_text("GXTODO_IOS_ENTITLEMENTS =\nGXTODO_APNS_ENVIRONMENT = disabled\n", encoding="utf-8")
                print("App Store profile has no APNs entitlement; remote notifications are unavailable in this build.")
            return
    sys.exit("Could not match the App Store provisioning profile for the Todo app.")


if __name__ == "__main__":
    main()
