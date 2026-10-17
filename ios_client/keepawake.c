// 탈옥 폰용: 화면이 꺼져도 폰(CPU·Wi-Fi)이 잠들지 않게 전원 assertion을 쥐고 있는다. 화면은 꺼진 채 둔다.
// 서버가 꺼진 동안 폰이 잠들면 snapclient의 1초 재접속 타이머가 몇 분씩 멈춘다(2026-10-08 로그: 최대 25분).
// snapclient 래퍼(run)가 띄우고, 부모(snapclient)가 끝나면 같이 끝난다.
//   keepawake            assertion을 쥐고 대기
//   keepawake -n         assertion 없이 (비교 시험용)
//   keepawake -l FILE    10초마다 FILE에 시각 기록 (잠들었는지 확인용)
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef uint32_t IOPMAssertionID;
extern int IOPMAssertionCreateWithName(CFStringRef type, uint32_t level, CFStringRef name, IOPMAssertionID *id);
extern int IOPMAssertionRelease(IOPMAssertionID id);

// iOS powerd가 오래된 assertion을 몰래 풀어 버린다(2026-10-09 낮: 배터리 상태에서 10분 안에 PreventUserIdleSystemSleep=0, 폰이 다시 잠듦).
// 그래서 15초마다 새로 만들고 옛것을 푼다.
static int renew(IOPMAssertionID *a1, IOPMAssertionID *a2) {
    IOPMAssertionID n1 = 0, n2 = 0;
    int r1 = IOPMAssertionCreateWithName(CFSTR("PreventUserIdleSystemSleep"), 255, CFSTR("io.github.jangcuber.keepawake"), &n1);
    int r2 = IOPMAssertionCreateWithName(CFSTR("NoIdleSleepAssertion"), 255, CFSTR("io.github.jangcuber.keepawake"), &n2);
    if (*a1) IOPMAssertionRelease(*a1);
    if (*a2) IOPMAssertionRelease(*a2);
    *a1 = r1 ? 0 : n1;
    *a2 = r2 ? 0 : n2;
    return (r1 && r2) ? r1 : 0;
}

int main(int argc, char **argv) {
    int take = 1;
    const char *logpath = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-n")) take = 0;
        else if (!strcmp(argv[i], "-l") && i + 1 < argc) logpath = argv[++i];
    }
    IOPMAssertionID a1 = 0, a2 = 0;
    if (take) {
        int r = renew(&a1, &a2);
        fprintf(stderr, "keepawake: assertion %s\n", r ? "FAILED" : "ok");
        if (r) return 1;
    }
    const pid_t parent = getppid();
    for (;;) {
        if (getppid() != parent) return 0; // snapclient가 끝남 (launchd가 다시 띄우면 새 keepawake도 함께 뜬다)
        if (logpath) {
            FILE *f = fopen(logpath, "a");
            if (f) {
                time_t t = time(NULL);
                char buf[32];
                strftime(buf, sizeof buf, "%Y-%m-%d %H:%M:%S", localtime(&t));
                fprintf(f, "%s %s\n", buf, take ? "awake" : "plain");
                fclose(f);
            }
        }
        sleep(logpath ? 10 : 15);
        if (take) renew(&a1, &a2);
    }
}
