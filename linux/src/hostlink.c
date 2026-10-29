/*
 * hostlink - talk to the Roblox host from inside Brick Linux.
 *
 *   hostlink [-i FILE] COMMAND [ARG...]
 *
 * Sends COMMAND (plus tab-separated ARGs, plus the contents of FILE as a binary
 * payload when -i is given; "-i -" reads stdin) to the host link device and
 * writes the host's reply to stdout. Exits 0 on success; on failure the reply is
 * printed to stderr and the exit status is 1.
 *
 * The device is plain MMIO at 0x10001000. This kernel has no MMU, so user
 * programs can poke it directly and hand it pointers into their own memory:
 * physical and virtual addresses are the same. No kernel driver is needed.
 *
 *   +0x00 REQ_ADDR   (w) address of the request
 *   +0x04 REQ_LEN    (w) request length in bytes
 *   +0x08 RESP_ADDR  (w) address of the response buffer
 *   +0x0C RESP_CAP   (w) response buffer capacity
 *   +0x10 CONTROL    (w) 1 = submit request, 2 = copy the pending response again
 *   +0x14 STATUS     (r) 0 idle, 1 busy, 2 ok, 3 error, 4 response too large
 *   +0x18 RESP_LEN   (r) response length (the needed size when STATUS is 4)
 *   +0x1C MAGIC      (r) 0x4B435242 ("BRCK")
 *
 * Request format: "COMMAND\tARG1\tARG2...\n" followed by the raw payload.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

#define HL_BASE 0x10001000u
#define HL_MAGIC 0x4B435242u

enum { REQ_ADDR = 0, REQ_LEN = 1, RESP_ADDR = 2, RESP_CAP = 3, CONTROL = 4, STATUS = 5, RESP_LEN = 6, MAGIC = 7 };
enum { ST_IDLE = 0, ST_BUSY = 1, ST_OK = 2, ST_ERR = 3, ST_TOO_LARGE = 4 };

static volatile uint32_t *const hl = (volatile uint32_t *)HL_BASE;

static unsigned char *read_all(int fd, size_t *len)
{
	size_t cap = 4096, n = 0;
	unsigned char *buf = malloc(cap);
	if (!buf)
		return NULL;
	for (;;) {
		if (n == cap) {
			unsigned char *bigger = realloc(buf, cap * 2);
			if (!bigger) {
				free(buf);
				return NULL;
			}
			buf = bigger;
			cap *= 2;
		}
		ssize_t r = read(fd, buf + n, cap - n);
		if (r < 0) {
			free(buf);
			return NULL;
		}
		if (r == 0)
			break;
		n += (size_t)r;
	}
	*len = n;
	return buf;
}

static uint32_t wait_done(void)
{
	uint32_t st;
	while ((st = hl[STATUS]) == ST_BUSY)
		usleep(2000);
	return st;
}

static int write_all(int fd, const unsigned char *p, size_t n)
{
	while (n > 0) {
		ssize_t w = write(fd, p, n);
		if (w <= 0)
			return -1;
		p += w;
		n -= (size_t)w;
	}
	return 0;
}

int main(int argc, char **argv)
{
	const char *infile = NULL;
	int argi = 1;

	if (argi + 1 < argc && strcmp(argv[argi], "-i") == 0) {
		infile = argv[argi + 1];
		argi += 2;
	}
	if (argi >= argc) {
		fprintf(stderr, "usage: hostlink [-i FILE] COMMAND [ARG...]\n");
		return 2;
	}
	if (hl[MAGIC] != HL_MAGIC) {
		fprintf(stderr, "hostlink: no host link device (are you running inside Roblox?)\n");
		return 2;
	}

	size_t payload_len = 0;
	unsigned char *payload = NULL;
	if (infile) {
		int fd = strcmp(infile, "-") == 0 ? 0 : open(infile, O_RDONLY);
		if (fd < 0) {
			perror(infile);
			return 2;
		}
		payload = read_all(fd, &payload_len);
		if (!payload) {
			perror("hostlink: read");
			return 2;
		}
		if (fd != 0)
			close(fd);
	}

	size_t header_len = 0;
	for (int i = argi; i < argc; i++)
		header_len += strlen(argv[i]) + 1;
	size_t req_len = header_len + payload_len;
	unsigned char *req = malloc(req_len ? req_len : 1);
	if (!req) {
		perror("hostlink");
		return 2;
	}
	size_t pos = 0;
	for (int i = argi; i < argc; i++) {
		size_t l = strlen(argv[i]);
		memcpy(req + pos, argv[i], l);
		pos += l;
		req[pos++] = (i + 1 < argc) ? '\t' : '\n';
	}
	if (payload_len)
		memcpy(req + pos, payload, payload_len);

	uint32_t cap = 64 * 1024;
	unsigned char *resp = malloc(cap);
	if (!resp) {
		perror("hostlink");
		return 2;
	}

	hl[REQ_ADDR] = (uint32_t)(uintptr_t)req;
	hl[REQ_LEN] = (uint32_t)req_len;
	hl[RESP_ADDR] = (uint32_t)(uintptr_t)resp;
	hl[RESP_CAP] = cap;
	hl[CONTROL] = 1;
	uint32_t st = wait_done();

	if (st == ST_TOO_LARGE) {
		cap = hl[RESP_LEN];
		free(resp);
		resp = malloc(cap ? cap : 1);
		if (!resp) {
			fprintf(stderr, "hostlink: response too large (%u bytes)\n", (unsigned)cap);
			return 2;
		}
		hl[RESP_ADDR] = (uint32_t)(uintptr_t)resp;
		hl[RESP_CAP] = cap;
		hl[CONTROL] = 2;
		st = wait_done();
	}

	uint32_t n = hl[RESP_LEN];
	if (n > cap)
		n = cap;
	if (st == ST_OK) {
		if (write_all(1, resp, n) < 0) {
			perror("hostlink: write");
			return 2;
		}
		return 0;
	}
	write_all(2, resp, n);
	if (n > 0 && resp[n - 1] != '\n')
		write_all(2, (const unsigned char *)"\n", 1);
	return 1;
}
