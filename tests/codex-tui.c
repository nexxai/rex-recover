/* Native stand-in so Rex observes a foreground process actually named codex. */
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *env(const char *key) {
    const char *value = getenv(key);
    return value ? value : "";
}

int main(int argc, char **argv) {
    char directory[PATH_MAX], cwd[PATH_MAX], path[PATH_MAX], input[128];
    if (strlen(argv[0]) >= sizeof directory || !getcwd(cwd, sizeof cwd)) return 1;
    strcpy(directory, argv[0]);
    char *slash = strrchr(directory, '/');
    if (!slash) return 1;
    *slash = '\0';

    snprintf(path, sizeof path, "%s/logs/%s.%ld", directory, env("REX_BLOCK"), (long)getpid());
    FILE *log = fopen(path, "wb");
    if (!log) return 1;
    fprintf(log, "%s%c%s%c%s%c", cwd, 0, env("CODEX_HOME"), 0, env("REX_RECOVER_SESSIONS"), 0);
    for (int index = 1; index < argc; index++) fprintf(log, "%s%c", argv[index], 0);
    if (fclose(log)) return 1;

    while (fgets(input, sizeof input, stdin)) {
        if (!strcmp(input, "exit\n")) return 0;
        if (!strcmp(input, "start\n")) {
            char node[PATH_MAX], hook[PATH_MAX];
            snprintf(path, sizeof path, "%s/hook", directory);
            FILE *command = fopen(path, "r");
            if (!command || !fgets(node, sizeof node, command) || !fgets(hook, sizeof hook, command)) return 1;
            fclose(command);
            node[strcspn(node, "\n")] = hook[strcspn(hook, "\n")] = '\0';
            int resume = (argc > 1 && !strcmp(argv[1], "resume")) || (argc > 2 && !strcmp(argv[2], "resume"));
            snprintf(path, sizeof path, "%s/fixture-%s.json", env("CODEX_HOME"), resume ? "resume" : "startup");
            pid_t child = fork();
            if (child < 0) return 1;
            if (child == 0) {
                int event = open(path, O_RDONLY);
                if (event < 0 || dup2(event, STDIN_FILENO) < 0 || setsid() < 0) _exit(1);
                close(event);
                // Match the native hook: shell exec leaves this PID as the helper's parent.
                execl("/bin/sh", "sh", "-c", "exec \"$@\"", "fixture-hook", node, hook, (char *)NULL);
                _exit(1);
            }
            int status;
            if (waitpid(child, &status, 0) != child || status) return 1;
        } else {
            snprintf(path, sizeof path, "%s/inputs/%s", directory, env("REX_BLOCK"));
            FILE *activity = fopen(path, "a");
            if (!activity) return 1;
            fputs(input, activity);
            if (fclose(activity)) return 1;
        }
    }
    return 0;
}
