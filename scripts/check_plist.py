import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f:
    data = plistlib.load(f)
for key in ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleName", "CFBundleShortVersionString",
            "CFBundleVersion", "UILaunchScreen", "UISupportedInterfaceOrientations", "NSAppTransportSecurity"]:
    print(key, "=", data.get(key))
print("keys:", sorted(data.keys()))
