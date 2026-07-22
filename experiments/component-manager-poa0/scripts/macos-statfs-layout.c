#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/utsname.h>

static void print_json_string(const char *value) {
    putchar('"');
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor; cursor++) {
        if (*cursor == '"' || *cursor == '\\') putchar('\\');
        if (*cursor >= 0x20) putchar(*cursor);
    }
    putchar('"');
}

static void print_hex(const unsigned char *value, size_t length) {
    putchar('"');
    for (size_t index = 0; index < length; index++) printf("%02x", value[index]);
    putchar('"');
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    struct statfs value;
    memset(&value, 0, sizeof(value));
    int return_code = statfs(argv[1], &value);
    int captured_errno = return_code == 0 ? 0 : errno;
    struct utsname system_info;
    if (uname(&system_info) != 0) return 3;
#if defined(__x86_64__)
    const char *symbol = "statfs$INODE64";
#elif defined(__arm64__)
    const char *symbol = "statfs";
#else
#error unsupported Darwin architecture
#endif
    printf("{\"architecture\":"); print_json_string(system_info.machine);
    printf(",\"header\":\"sys/mount.h\",\"symbol\":"); print_json_string(symbol);
    printf(",\"prototype\":\"int statfs(const char *, struct statfs *)\"");
    printf(",\"size\":%zu,\"alignment\":%zu", sizeof(struct statfs), _Alignof(struct statfs));
    printf(",\"mfsnamelen\":%d,\"mnamelen\":%d", MFSNAMELEN, MNAMELEN);
    printf(",\"offsets\":{\"f_fstypename\":%zu,\"f_mntonname\":%zu,\"f_mntfromname\":%zu}",
        offsetof(struct statfs, f_fstypename), offsetof(struct statfs, f_mntonname),
        offsetof(struct statfs, f_mntfromname));
    printf(",\"return_code\":%d,\"errno\":%d,\"filesystem_type\":", return_code, captured_errno);
    print_json_string(value.f_fstypename);
    printf(",\"mount_point\":"); print_json_string(value.f_mntonname);
    printf(",\"mounted_from\":"); print_json_string(value.f_mntfromname);
    printf(",\"fstypename_raw\":"); print_hex((const unsigned char *)value.f_fstypename, sizeof(value.f_fstypename));
    printf(",\"mntonname_raw_prefix\":"); print_hex((const unsigned char *)value.f_mntonname, 32);
    printf(",\"mntfromname_raw_prefix\":"); print_hex((const unsigned char *)value.f_mntfromname, 32);
    printf("}\n");
    return return_code == 0 ? 0 : 1;
}
