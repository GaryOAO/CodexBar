#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-/Applications/CodexBar.app}"
BUNDLE_ID="${BUNDLE_ID:-com.steipete.codexbar}"
PET_HELPER_APP="${PET_HELPER_APP:-$APP/Contents/Helpers/CodexBarPetBLEHelper.app}"
PET_HELPER_BUNDLE_ID="${PET_HELPER_BUNDLE_ID:-${BUNDLE_ID}.petblehelper}"
PET_SERVICE_UUID="c0dec0de-0000-1000-8000-00805f9b34fb"

section() {
  printf '\n==> %s\n' "$1"
}

read_default() {
  local domain="$1"
  local key="$2"
  local value
  printf '%s.%s=' "$domain" "$key"
  value=$(defaults read "$domain" "$key" 2>/dev/null || true)
  printf '%s\n' "$value"
}

team_identifier() {
  local app="$1"
  codesign -dv "$app" 2>&1 | awk -F= '/TeamIdentifier/ { print $2; exit }'
}

entitlement_groups() {
  local app="$1"
  codesign -d --entitlements :- "$app" 2>/dev/null \
    | python3 -c 'import plistlib,sys
data=sys.stdin.buffer.read()
try:
    plist=plistlib.loads(data)
except Exception:
    plist={}
print("\n".join(plist.get("com.apple.security.application-groups", [])))' 2>/dev/null || true
}

section "Installed app"
if [[ ! -d "$APP" ]]; then
  echo "missing app: $APP"
  exit 1
fi
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Runtime' || true
APP_TEAM_IDENTIFIER=$(team_identifier "$APP")
if [[ -z "${APP_GROUP_ID:-}" ]]; then
  if [[ "$BUNDLE_ID" == *".debug"* ]]; then
    APP_GROUP_ID="${APP_TEAM_IDENTIFIER}.com.steipete.codexbar.debug"
  else
    APP_GROUP_ID="${APP_TEAM_IDENTIFIER}.com.steipete.codexbar"
  fi
fi

section "Entitlements"
entitlements_xml=$(codesign -d --entitlements - "$APP" 2>&1 || true)
echo "$entitlements_xml" | grep -E 'bluetooth|application-groups|app-sandbox' || true
app_groups=$(entitlement_groups "$APP")
if [[ -n "$APP_TEAM_IDENTIFIER" && -n "$app_groups" ]] \
  && ! grep -Fxq "$APP_GROUP_ID" <<<"$app_groups"
then
  echo "WARN: app-group entitlement does not match TeamIdentifier-derived group."
  echo "      TeamIdentifier=$APP_TEAM_IDENTIFIER expected=$APP_GROUP_ID actual=$(tr '\n' ',' <<<"$app_groups" | sed 's/,$//')"
fi
has_bluetooth=0
has_sandbox=0
if echo "$entitlements_xml" | grep -q 'com.apple.security.device.bluetooth'; then
  has_bluetooth=1
fi
if echo "$entitlements_xml" | grep -q 'com.apple.security.app-sandbox'; then
  has_sandbox=1
fi
if [[ "$has_bluetooth" == "1" && "$has_sandbox" != "1" ]]; then
  echo "WARN: bluetooth entitlement is present, but app-sandbox is absent."
  echo "      Apple documents com.apple.security.device.bluetooth as an App Sandbox hardware entitlement."
  echo "      If authorization stays notDetermined, consider a sandboxed BLE helper or carefully sandboxing the app."
fi

section "Pet BLE helper"
if [[ -d "$PET_HELPER_APP" ]]; then
  codesign -dv "$PET_HELPER_APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Runtime' || true
  helper_entitlements_xml=$(codesign -d --entitlements - "$PET_HELPER_APP" 2>&1 || true)
  echo "$helper_entitlements_xml" | grep -E 'bluetooth|application-groups|app-sandbox' || true
  helper_groups=$(entitlement_groups "$PET_HELPER_APP")
  if [[ -n "$APP_TEAM_IDENTIFIER" && -n "$helper_groups" ]] \
    && ! grep -Fxq "$APP_GROUP_ID" <<<"$helper_groups"
  then
    echo "WARN: helper app-group entitlement does not match main TeamIdentifier-derived group."
    echo "      TeamIdentifier=$APP_TEAM_IDENTIFIER expected=$APP_GROUP_ID actual=$(tr '\n' ',' <<<"$helper_groups" | sed 's/,$//')"
  fi
  if echo "$helper_entitlements_xml" | grep -q 'com.apple.security.device.bluetooth' \
    && echo "$helper_entitlements_xml" | grep -q 'com.apple.security.app-sandbox'
  then
    echo "helper entitlement shape OK"
  else
    echo "WARN: helper is missing sandbox and/or bluetooth entitlement"
  fi
else
  echo "helper missing: $PET_HELPER_APP"
fi

section "Runtime defaults"
read_default "$BUNDLE_ID" petRuntimeDetail
read_default "$BUNDLE_ID" petBleState
read_default "$BUNDLE_ID" petBleAuthorization
read_default "$BUNDLE_ID" petBleRuntimeDetail
read_default "$BUNDLE_ID" petBleRuntimeUpdatedAt
read_default "$APP_GROUP_ID" petBLEHelperRuntimeDetail
read_default "$APP_GROUP_ID" petBLEHelperRuntimeUpdatedAt
read_default "$APP_GROUP_ID" petBLEHelperCommandID
read_default "$APP_GROUP_ID" petBLEHelperEventID
read_default "$PET_HELPER_BUNDLE_ID" petBleState
read_default "$PET_HELPER_BUNDLE_ID" petBleAuthorization
read_default "$PET_HELPER_BUNDLE_ID" petBleRuntimeDetail

section "App Group IPC files"
GROUP_DIR="$HOME/Library/Group Containers/$APP_GROUP_ID"
if [[ -d "$GROUP_DIR" ]]; then
  for name in pet-ble-command.json pet-ble-event.json pet-ble-snapshot.json; do
    if [[ -f "$GROUP_DIR/$name" ]]; then
      printf '%s: ' "$name"
      python3 - "$GROUP_DIR/$name" <<'PY' || true
import json, sys
path = sys.argv[1]
data = json.load(open(path))
if "requestID" in data and "command" in data:
    print(f"request={data['requestID']} command={list(data['command'].keys())[0] if isinstance(data['command'], dict) else data['command']}")
elif "snapshot" in data:
    snap = data["snapshot"].get("_1", {}) if isinstance(data["snapshot"], dict) else {}
    print(f"snapshot state={snap.get('state','?')} firmware={snap.get('firmwareInfo','?')}")
else:
    print(json.dumps(data)[:180])
PY
    else
      echo "$name: missing"
    fi
  done
else
  echo "missing group container: $GROUP_DIR"
fi

section "TCC Bluetooth rows"
tcc_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
tcc_query="select service,client,auth_value,auth_reason,last_modified from access where client like '%codexbar%' or client='${BUNDLE_ID}' or client='${PET_HELPER_BUNDLE_ID}';"
set +e
tcc_output=$(sqlite3 "$tcc_db" "$tcc_query" 2>&1)
tcc_status=$?
set -e
if [[ "$tcc_status" -ne 0 ]]; then
  echo "TCC_DB_UNREADABLE: $tcc_output"
  echo "Tip: grant Terminal/Codex Full Disk Access to inspect TCC rows, or use System Settings → Privacy & Security → Bluetooth."
elif [[ -n "$tcc_output" ]]; then
  echo "$tcc_output"
else
  echo "no TCC row for ${BUNDLE_ID}"
fi

section "External BLE scan"
python_candidates=()
if [[ -n "${PYTHON_BIN:-}" ]]; then
  python_candidates+=("$PYTHON_BIN")
fi
if [[ -x /opt/homebrew/Caskroom/miniconda/base/bin/python3 ]]; then
  python_candidates+=("/opt/homebrew/Caskroom/miniconda/base/bin/python3")
fi
if command -v python3 >/dev/null 2>&1; then
  python_candidates+=("$(command -v python3)")
fi

python_bin=""
for candidate in "${python_candidates[@]}"; do
  if "$candidate" - <<'PY' >/dev/null 2>&1
import bleak
PY
  then
    python_bin="$candidate"
    break
  fi
done

if [[ -z "$python_bin" ]]; then
  echo "python3 not found; skipping scan"
  exit 0
fi

"$python_bin" - <<PY || true
import asyncio
from bleak import BleakScanner

SERVICE = "$PET_SERVICE_UUID"

async def main():
    devs = await BleakScanner.discover(timeout=4, return_adv=True)
    for dev, adv in devs.values():
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        if dev.name == "ClawdPet" or SERVICE in uuids:
            print(f"FOUND {dev.address} {dev.name} rssi={adv.rssi} uuids={uuids}")
            return
    print("NOT_FOUND_OR_CONNECTED")

asyncio.run(main())
PY
