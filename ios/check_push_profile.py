"""Require production APNs in the App Store profile and exported IPA."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


def configure_signing(export, bundle_id):
    selected = plistlib.loads(export.read_bytes()).get("provisioningProfiles", {}).get(bundle_id)
    if not selected:
        sys.exit("No App Store provisioning profile was selected for " + bundle_id)
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
            if entitlements.get("aps-environment") != "production":
                sys.exit("The selected App Store profile lacks production APNs. Enable Push Notifications "
                         "for the App ID and regenerate the App Store profile in Codemagic.")
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
            return
    sys.exit("Could not match the App Store provisioning profile for the Todo app.")


def verify_ipa(ipa, bundle_id):
    with TemporaryDirectory() as directory:
        subprocess.run(["ditto", "-x", "-k", str(ipa), directory], check=True)
        apps = list((Path(directory) / "Payload").glob("*.app"))
        if len(apps) != 1:
            sys.exit("Expected one application in the exported IPA.")
        app = apps[0]
        info = plistlib.loads((app / "Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != bundle_id or info.get("TodoPushEnvironment") != "production":
            sys.exit("The exported app does not identify itself as a production APNs build.")
        signed = subprocess.check_output(["codesign", "-d", "--entitlements", "-", str(app)])
        if not signed or plistlib.loads(signed).get("aps-environment") != "production":
            sys.exit("The exported app signature lacks the production APNs entitlement.")
        print("Verified production APNs in the exported IPA signature.")


if __name__ == "__main__":
    if sys.argv[1] == "--ipa":
        verify_ipa(Path(sys.argv[2]), sys.argv[3])
    else:
        configure_signing(Path(sys.argv[1]), sys.argv[2])
