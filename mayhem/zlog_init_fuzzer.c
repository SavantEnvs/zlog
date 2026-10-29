/* Fuzz zlog's configuration parser: write the input to a scratch conf file, zlog_init() it, tear it down. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "zlog.h"

static char conf_path[4096];

static void remove_conf(void)
{
	if (conf_path[0])
		unlink(conf_path);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	FILE *fp;

	/* a "|cmd" rule is popen()ed when the conf is built: keep the fuzzer from running commands */
	if (memchr(data, '|', size))
		return -1;

	if (!conf_path[0]) {
		const char *dir = getenv("TMPDIR");
		int fd;

		snprintf(conf_path, sizeof(conf_path), "%s/zlog_fuzz_XXXXXX", dir && *dir ? dir : "/tmp");
		fd = mkstemp(conf_path);
		if (fd < 0) {
			conf_path[0] = '\0';
			return -1;
		}
		close(fd);
		atexit(remove_conf);
	}

	fp = fopen(conf_path, "wb");
	if (!fp)
		return -1;
	if (size && fwrite(data, size, 1, fp) != 1) {
		fclose(fp);
		return -1;
	}
	fclose(fp);

	if (zlog_init(conf_path))
		return -1;

	zlog_fini();
	return 0;
}
