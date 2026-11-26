/* The per-user icon index of IconServices (<DARWIN_USER_CACHE_DIR>/com.apple.iconservices/store.index), in the format of macOS 26.7.2.
 * Format and evidence: research/docs/ICONSERVICES-WIRE.md section 7.1 (github.com/pearOS-bsd/research).  The clients map the file and read it without IPC;
 * the agent is the only writer.  Our own code (BSD-2-Clause). */
#ifndef IS_STORE_INDEX_H
#define IS_STORE_INDEX_H
#include <stdint.h>
#include <stddef.h>

#define IS_INDEX_VERSION        0x0b
#define IS_INDEX_HEADER         0x14            /* version, flag, count, capacity, unallocated */
#define IS_INDEX_NODE_SIZE      0x98            /* 152 = 0x24 node header + payload */
#define IS_INDEX_PAYLOAD_SIZE   0x74            /* 116 */
#define IS_INDEX_CAPACITY       4000            /* buckets of a new index (the value seen on the Mac) */

/* the payload: the struct passed to -[ISMutableStoreIndex addValue:], {?=[16C]{CGSize}dI[16C][16C]{?=[16C]Q[16C]}}, packed as on disk */
typedef struct is_index_value {
	uint8_t  icon_digest[16];       /* key */
	double   size_from;             /* valid size range: lower bound (points) */
	double   size_to;               /* upper bound */
	double   nominal;               /* size the bitmap was rendered at */
	uint32_t scale;                 /* 1, 2 */
	uint8_t  descriptor_digest[16];
	uint8_t  unit_uuid[16];         /* the file <UUID>.isdata of the store */
	uint8_t  token[40];             /* validation token: LS database UUID, LS sequence (u64 le), RSC UUID */
} __attribute__((packed)) is_index_value;

/* adds a value (appends a node, chains it at the tail of its bucket); creates the file when it does not exist.  0 on success, -1 with errno. */
int is_index_add(const char *path, const is_index_value *v);
/* finds the newest valid value for the icon digest whose descriptor digest and scale match and whose range holds `size`; 1 found, 0 not found, -1 error */
int is_index_find(const char *path, const uint8_t icon_digest[16], const uint8_t descriptor_digest[16], uint32_t scale, double size, is_index_value *out);
/* walks every node: checks the header, each bucket chain (node in the right bucket, offsets growing) and the node count.  Returns the number of errors, -1 if unreadable. */
int is_index_verify(const char *path, int *nodes);
#endif
