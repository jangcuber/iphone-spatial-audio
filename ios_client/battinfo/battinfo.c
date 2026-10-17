// 배터리 조회 (iOS 17+는 mobile 권한 ioreg가 비어 있어 IOPowerSources로 읽음)
// 출력: <퍼센트>|<충전기 연결 Yes/No>|<충전 중 Yes/No>|<완충 Yes/No>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
extern CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob);
extern CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps);

static int num(CFDictionaryRef d, const char *k) {
  CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
  CFNumberRef n = CFDictionaryGetValue(d, key); CFRelease(key);
  int v = -1; if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberIntType, &v);
  return v;
}
static const char *flag(CFDictionaryRef d, const char *k) {
  CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
  CFTypeRef b = CFDictionaryGetValue(d, key); CFRelease(key);
  return (b && CFGetTypeID(b) == CFBooleanGetTypeID()) ? (CFBooleanGetValue(b) ? "Yes" : "No") : "";
}
static int eq(CFDictionaryRef d, const char *k, const char *want) {
  CFStringRef key = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
  CFStringRef s = CFDictionaryGetValue(d, key); CFRelease(key);
  char buf[64] = "";
  if (s && CFGetTypeID(s) == CFStringGetTypeID()) CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
  return strcmp(buf, want) == 0;
}

int main(void) {
  CFTypeRef blob = IOPSCopyPowerSourcesInfo();
  if (!blob) return 1;
  CFArrayRef list = IOPSCopyPowerSourcesList(blob);
  for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
    CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
    if (!d) continue;
    int cur = num(d, "Current Capacity"), max = num(d, "Max Capacity");
    int pct = (max > 0 && cur >= 0) ? (cur * 100 + max / 2) / max : cur;
    printf("%d|%s|%s|%s\n", pct, eq(d, "Power Source State", "AC Power") ? "Yes" : "No",
           flag(d, "Is Charging"), flag(d, "Is Charged"));
    return 0;
  }
  return 1;
}
