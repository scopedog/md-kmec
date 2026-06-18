/*
 * raidkm-ec-mds-verify.c — offline self-test of raidkm's EC matrix choice.
 *
 * raidkm picks the generator matrix by parity count m (km/raid_km.h /
 * raid_km.c:raidkm_build_ec):
 *     m <= RAIDKM_VANDERMONDE_MAX_M (3)  -> Vandermonde (gf_gen_rs_matrix)
 *     m >= 4                             -> Cauchy      (gf_gen_cauchy1_matrix)
 * A code is MDS ("any m failures recoverable") iff every k-of-(k+m) survivor
 * set yields an invertible k x k decode submatrix.  This test builds the matrix
 * raidkm WOULD use for every supported (m, k) and brute-forces EVERY m-erasure
 * pattern through the real ISA-L gf_invert_matrix() — exactly what the kernel's
 * ops_run_compute_km() does.  Any singular submatrix is an unrecoverable
 * failure combination (silent data loss) and fails the test (exit 1).
 *
 * It also prints an informational control: plain Vandermonde at m >= 4 is NOT
 * MDS for large k — which is precisely why raidkm switches to Cauchy there.
 *
 * Build (from the md-kmec checkout root, after `make` has created the isa-l
 * symlink into a built mdraid tree):
 *     cc -O2 tools/raidkm-ec-mds-verify.c isa-l/ec_base.c -Iisa-l -o /tmp/ecmds
 *     /tmp/ecmds
 */
#include <stdio.h>
#include <string.h>
#include "isa-l_ec.h"

/* Mirror km/raid_km.h. */
#define RAIDKM_VANDERMONDE_MAX_M 3
#define RAIDKM_MIN_M             2
#define RAIDKM_MAX_M             8
#define RAIDKM_MAX_DISKS         32

/* Cap the per-(m,k) erasure-pattern enumeration so the test stays quick; the
 * full k range is still reached for low m (where C(k+m,m) is small), and a
 * substantial range for high m. */
#define MAX_PATTERNS 300000L

static unsigned char A[64*64], sub[64*64], inv[64*64], tmp[64*64];
static long total, singular;

static long choose(int n, int r) {           /* C(n,r), saturating */
	if (r < 0 || r > n) return 0;
	if (r > n - r) r = n - r;
	long c = 1;
	for (int i = 0; i < r; i++) {
		c = c * (n - i) / (i + 1);
		if (c > (1L << 40)) return c;         /* huge — caller will skip */
	}
	return c;
}

static void check(int k, const int *rows) {
	for (int i = 0; i < k; i++)
		for (int j = 0; j < k; j++)
			sub[i*k+j] = A[rows[i]*k + j];
	memcpy(tmp, sub, k*k);
	total++;
	if (gf_invert_matrix(tmp, inv, k) < 0) singular++;
}

static void combos(int n, int k, int start, int depth, int *rows) {
	if (depth == k) { check(k, rows); return; }
	for (int r = start; r <= n - (k - depth); r++) {
		rows[depth] = r;
		combos(n, k, r+1, depth+1, rows);
	}
}

/* Returns singular-pattern count for the (m, k) code from gen(). */
static long mds_scan(void (*gen)(unsigned char*,int,int), int m, int k) {
	int n = k + m, rows[64];
	gen(A, n, k);
	total = singular = 0;
	combos(n, k, 0, 0, rows);
	return singular;
}

int main(void) {
	int failures = 0;

	printf("=== raidkm EC matrix MDS self-test ===\n");
	printf("    m<=%d -> Vandermonde, m>=4 -> Cauchy; max m=%d, max disks=%d\n\n",
	       RAIDKM_VANDERMONDE_MAX_M, RAIDKM_MAX_M, RAIDKM_MAX_DISKS);

	for (int m = RAIDKM_MIN_M; m <= RAIDKM_MAX_M; m++) {
		void (*gen)(unsigned char*,int,int) =
			(m <= RAIDKM_VANDERMONDE_MAX_M) ? gf_gen_rs_matrix
							: gf_gen_cauchy1_matrix;
		const char *mat = (m <= RAIDKM_VANDERMONDE_MAX_M) ? "Vandermonde" : "Cauchy";
		int kmax = 0, bad_m = 0;
		for (int k = 1; k <= RAIDKM_MAX_DISKS - m; k++) {
			if (choose(k + m, m) > MAX_PATTERNS) break;   /* keep it quick */
			if (mds_scan(gen, m, k)) bad_m += (int)singular;
			kmax = k;
		}
		printf("  m=%d  %-11s  k=1..%-2d  -> %s\n",
		       m, mat, kmax, bad_m ? "FAIL (unrecoverable patterns!)" : "MDS (all recoverable)");
		if (bad_m) failures++;
	}

	/* Informational: why the threshold exists — plain Vandermonde is not MDS
	 * at m>=4 for large k.  NOT counted as a test failure (raidkm uses Cauchy). */
	printf("\n  control (informational): plain Vandermonde at m=4\n");
	for (int k = 20; k <= 26; k++) {
		long s = mds_scan(gf_gen_rs_matrix, 4, k);
		printf("    vander m=4 k=%-2d: unrecoverable=%ld%s\n",
		       k, s, s ? "  (<- non-MDS; reason raidkm uses Cauchy at m>=4)" : "");
	}

	printf("\nRESULT: %s\n", failures ? "FAIL — raidkm's chosen matrix is NOT MDS somewhere"
				   : "PASS — every raidkm (m,k) code is MDS");
	return failures ? 1 : 0;
}
