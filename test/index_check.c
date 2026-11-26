/* store.index: adds values with random keys to a new index, then checks every chain, the count and the lookups.  Format: research/docs/ICONSERVICES-WIRE.md 7.1. */
#include "../common/store_index.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/tmp/is-index-check.index";
	unlink(path);
	srand(7);
	enum { N = 2500 };                                 /* more than one file's worth of nodes: exercises the growth */
	static is_index_value v[N];
	for (int i = 0; i < N; i++) {
		for (int k = 0; k < 16; k++) { v[i].icon_digest[k] = (uint8_t)rand(); v[i].unit_uuid[k] = (uint8_t)rand(); }
		if (i % 7 == 0 && i) memcpy(v[i].icon_digest, v[i - 1].icon_digest, 16);    /* same icon, another size */
		v[i].size_from = 16 + (i % 3) * 100; v[i].size_to = v[i].nominal = v[i].size_from + 50; v[i].scale = 1 + i % 2;
		if (is_index_add(path, &v[i]) < 0) { perror("add"); return 1; }
	}
	int nodes = 0, err = is_index_verify(path, &nodes);
	int missing = 0;
	for (int i = 0; i < N; i++) {
		is_index_value o;
		if (is_index_find(path, v[i].icon_digest, v[i].descriptor_digest, v[i].scale, v[i].size_from + 1, &o) != 1) missing++;
	}
	printf("index_check: %d nodes, %d chain errors, %d lookups missed\n", nodes, err, missing);
	unlink(path);
	return err || nodes != N || missing ? 1 : 0;
}
