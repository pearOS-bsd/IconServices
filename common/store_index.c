/* store.index of IconServices: a hash table of fixed buckets followed by a node area (research/docs/ICONSERVICES-WIRE.md 7.1).
 *   header  u32 version 0x0b, u32 flag 1, u32 count, u32 capacity, u32 unallocated (bytes used in the node area)
 *   buckets u64[capacity] = (size << 32) | offset of the first node of the chain (offset relative to the node area), 0 = empty
 *   nodes   u64 self ref, uuid key, u64 next ref, u8 valid, 3 bytes 0, payload (116 bytes)
 * bucket = (key_u64[0] ^ key_u64[1]) % capacity (little-endian halves).  A new node goes at `unallocated` and is linked at the tail of its chain. */
#include "store_index.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/file.h>
#include <sys/stat.h>

static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void wr64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static uint64_t ref(uint32_t off) { return ((uint64_t)IS_INDEX_NODE_SIZE << 32) | off; }
static uint32_t bucket_of(const uint8_t key[16], uint32_t cap) { return (uint32_t)((rd64(key) ^ rd64(key + 8)) % cap); }
static size_t round_page(size_t n) { size_t pg = (size_t)getpagesize(); return (n + pg - 1) / pg * pg; }

static int pread_all(int fd, void *b, size_t n, off_t o) { return pread(fd, b, n, o) == (ssize_t)n ? 0 : -1; }
static int pwrite_all(int fd, const void *b, size_t n, off_t o) { return pwrite(fd, b, n, o) == (ssize_t)n ? 0 : -1; }

/* a new, empty index: the mapping size of the Mac (+[NSData mappedDataWithCapacity:additionalSize:]: pagesize + capacity * 0x2c + 0x13, page rounded) */
static int create_empty(int fd)
{
	uint8_t h[IS_INDEX_HEADER] = { 0 };
	size_t size = round_page((size_t)getpagesize() + (size_t)IS_INDEX_CAPACITY * 0x2c + 0x13);
	wr32(h, IS_INDEX_VERSION); wr32(h + 4, 1); wr32(h + 8, 0); wr32(h + 12, IS_INDEX_CAPACITY); wr32(h + 16, 0);
	if (ftruncate(fd, 0) < 0 || ftruncate(fd, (off_t)size) < 0) return -1;
	return pwrite_all(fd, h, sizeof h, 0);
}

static int read_header(int fd, uint32_t *count, uint32_t *cap, uint32_t *unalloc)
{
	uint8_t h[IS_INDEX_HEADER];
	if (pread_all(fd, h, sizeof h, 0) < 0 || rd32(h) != IS_INDEX_VERSION) { errno = EINVAL; return -1; }
	*count = rd32(h + 8); *cap = rd32(h + 12); *unalloc = rd32(h + 16);
	if (*cap == 0) { errno = EINVAL; return -1; }
	return 0;
}

int is_index_add(const char *path, const is_index_value *v)
{
	int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
	if (fd < 0) return -1;
	int rc = -1;
	struct stat st;
	uint32_t count, cap, unalloc;
	if (flock(fd, LOCK_EX) < 0 || fstat(fd, &st) < 0) goto out;
	if (st.st_size < IS_INDEX_HEADER || read_header(fd, &count, &cap, &unalloc) < 0) {
		if (create_empty(fd) < 0 || read_header(fd, &count, &cap, &unalloc) < 0 || fstat(fd, &st) < 0) goto out;
	}
	off_t area = IS_INDEX_HEADER + (off_t)cap * 8;
	uint32_t off = unalloc;
	if (area + off + IS_INDEX_NODE_SIZE > st.st_size) {             /* full: grow the file (the Mac extends its mapping the same way, by whole pages) */
		if (ftruncate(fd, (off_t)round_page((size_t)(area + off + IS_INDEX_NODE_SIZE) + (size_t)cap * 0x2c)) < 0) goto out;
	}
	uint8_t node[IS_INDEX_NODE_SIZE] = { 0 };
	wr64(node, ref(off)); memcpy(node + 0x08, v->icon_digest, 16); wr64(node + 0x18, 0); node[0x20] = 1;
	memcpy(node + 0x24, v, IS_INDEX_PAYLOAD_SIZE);
	if (pwrite_all(fd, node, sizeof node, area + off) < 0) goto out;
	/* link: the bucket when empty, else the tail of the chain */
	uint32_t b = bucket_of(v->icon_digest, cap);
	uint8_t r8[8];
	if (pread_all(fd, r8, 8, IS_INDEX_HEADER + (off_t)b * 8) < 0) goto out;
	uint64_t cur = rd64(r8);
	if (cur == 0) {
		wr64(r8, ref(off)); if (pwrite_all(fd, r8, 8, IS_INDEX_HEADER + (off_t)b * 8) < 0) goto out;
	} else {
		for (int guard = 0; guard < 1000000; guard++) {
			uint32_t co = (uint32_t)cur;
			if (pread_all(fd, r8, 8, area + co + 0x18) < 0) goto out;
			uint64_t next = rd64(r8);
			if (next == 0) { wr64(r8, ref(off)); if (pwrite_all(fd, r8, 8, area + co + 0x18) < 0) goto out; break; }
			if ((uint32_t)next <= co) { errno = EINVAL; goto out; }     /* cyclic chain: the Mac resets the index in that case */
			cur = next;
		}
	}
	uint8_t h[12];
	wr32(h, count + 1); wr32(h + 4, cap); wr32(h + 8, off + IS_INDEX_NODE_SIZE);
	if (pwrite_all(fd, h, sizeof h, 8) < 0) goto out;
	rc = 0;
out:
	{ int e = errno; close(fd); errno = e; }
	return rc;
}

int is_index_find(const char *path, const uint8_t icon_digest[16], const uint8_t descriptor_digest[16], uint32_t scale, double size, is_index_value *out)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return errno == ENOENT ? 0 : -1;
	int found = 0;
	uint32_t count, cap, unalloc;
	if (read_header(fd, &count, &cap, &unalloc) < 0) { close(fd); return -1; }
	off_t area = IS_INDEX_HEADER + (off_t)cap * 8;
	uint8_t r8[8], node[IS_INDEX_NODE_SIZE];
	if (pread_all(fd, r8, 8, IS_INDEX_HEADER + (off_t)bucket_of(icon_digest, cap) * 8) == 0) {
		for (uint64_t cur = rd64(r8); cur; ) {
			uint32_t co = (uint32_t)cur;
			if (co + IS_INDEX_NODE_SIZE > unalloc || pread_all(fd, node, sizeof node, area + co) < 0) break;
			is_index_value v; memcpy(&v, node + 0x24, sizeof v);
			if (node[0x20] && !memcmp(node + 8, icon_digest, 16) && !memcmp(v.descriptor_digest, descriptor_digest, 16) && v.scale == scale && size >= v.size_from && size <= v.size_to) { *out = v; found = 1; }
			uint64_t next = rd64(node + 0x18);
			if (next && (uint32_t)next <= co) break;
			cur = next;
		}
	}
	close(fd);
	return found;
}

int is_index_verify(const char *path, int *nodes)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return -1;
	uint32_t count, cap, unalloc;
	if (read_header(fd, &count, &cap, &unalloc) < 0) { close(fd); return -1; }
	off_t area = IS_INDEX_HEADER + (off_t)cap * 8;
	int errors = 0, seen = 0;
	uint8_t r8[8], node[IS_INDEX_NODE_SIZE];
	for (uint32_t b = 0; b < cap; b++) {
		if (pread_all(fd, r8, 8, IS_INDEX_HEADER + (off_t)b * 8) < 0) { errors++; break; }
		for (uint64_t cur = rd64(r8); cur; ) {
			uint32_t co = (uint32_t)cur;
			if ((cur >> 32) != IS_INDEX_NODE_SIZE || co + IS_INDEX_NODE_SIZE > unalloc || pread_all(fd, node, sizeof node, area + co) < 0) { errors++; break; }
			if (rd64(node) != cur || bucket_of(node + 8, cap) != b || memcmp(node + 8, node + 0x24, 16)) errors++;
			seen++;
			uint64_t next = rd64(node + 0x18);
			if (next && (uint32_t)next <= co) { errors++; break; }
			cur = next;
		}
	}
	if ((uint32_t)seen != count || (uint32_t)seen * IS_INDEX_NODE_SIZE != unalloc) errors++;
	if (nodes) *nodes = seen;
	close(fd);
	return errors;
}
