/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _RAID5_H
#define _RAID5_H

#include <linux/raid/xor.h>
#include <linux/dmaengine.h>
#include <linux/local_lock.h>

#include "raid_km_reshape.h"

/*
 * md personality level for raid_km.  Chosen to not collide with
 * stock raid4 (4), raid5 (5), raid6 (6), or the prototype kmec (70).
 */
#define RAID_KM_LEVEL	71

/*
 * "Wants raid6-style P+Q math" predicate.  Until the k+m
 * generalization replaces raid6_call with ISA-L EC primitives,
 * raid_km arrays at level 71 use the same XOR-based math as raid6.
 * Use this whenever a check like `level == 6` is asking "do we
 * have a Q parity disk / do raid6 math?" rather than "is this the
 * raid6 personality specifically?".
 */
static inline bool is_raid6_math(int level)
{
	return level == 6 || level == RAID_KM_LEVEL;
}

/*
 * raid_km redesign: maximum m supported by this build.  Dispatch by m:
 *   m == 2          raid6_call P+Q hardware (byte-identical to ISA-L)
 *   3 <= m <= 3     ISA-L ec_encode_data_* over a Vandermonde RS matrix
 *                   (gf_gen_rs_matrix) — keeps the m=2 raid6 equivalence
 *                   and is MDS at these small k+m
 *   4 <= m          ISA-L ec_encode_data_* over a Cauchy matrix
 *                   (gf_gen_cauchy1_matrix) — guaranteed MDS where
 *                   Vandermonde's k x k submatrices can go singular
 * Above RAIDKM_MAX_M is rejected at create time.  Capped so k + m stays
 * within RAIDKM_MAX_STRIPE_DISKS.
 */
#define RAIDKM_MAX_M	16	/* parity cap; kept small by design — it sizes the
				 * per-stripe [RAIDKM_MAX_M] arrays (ppl_pages in
				 * struct stripe_head, failed_num in stripe_head_state) */
#define RAIDKM_VANDERMONDE_MAX_M	3

/*
 * raid_km redesign: layout selector packed into mddev->layout.
 *
 * For raidkm (level 71) mddev->layout does NOT hold an ALGORITHM_* value
 * (those are raid5/6 specific); instead the low byte carries the parity
 * count m and one high bit selects the parity-placement layout:
 *
 *   bits [7:0]  m, the parity count (2..RAIDKM_MAX_M)
 *   bit  8      RAIDKM_LAYOUT_ROTATING — clear: fixed PARITY_N (the dedicated-
 *               parity layout, RAID4-style, with the cheap add-a-parity grow);
 *               set: rotating parity (generalized left-symmetric) that spreads
 *               parity and read traffic across all disks.
 *
 * Stored verbatim in the superblock layout field, so the choice persists
 * across assemble.  A plain `--layout=m` (no high bits) is PARITY_N, keeping
 * every existing array bit-for-bit compatible.
 */
#define RAIDKM_LAYOUT_M_MASK	0x00ff
#define RAIDKM_LAYOUT_ROTATING	0x0100
/* bits that carry meaning; anything else set is rejected at create time */
#define RAIDKM_LAYOUT_KNOWN	(RAIDKM_LAYOUT_M_MASK | RAIDKM_LAYOUT_ROTATING)

static inline int raidkm_layout_m(int layout)
{
	return layout & RAIDKM_LAYOUT_M_MASK;
}
static inline bool raidkm_layout_is_rotating(int layout)
{
	return !!(layout & RAIDKM_LAYOUT_ROTATING);
}

/*
 * Upper bound on disks per stripe (k data + m parity) for raidkm.  Set to the
 * GF(2^8) Reed-Solomon field limit: ISA-L needs k + m <= 255 distinct generator
 * points (Vandermonde for m <= 3, Cauchy for m >= 4), so this is the widest an
 * MDS code over one byte can stripe.  Sizes the per-cpu decode scratch and the
 * heap working arrays in the synchronous ISA-L paths (the large temporaries are
 * off-stack: per-cpu under conf->percpu->lock, or kmalloc'd on the rare
 * reshape/geometry paths).
 */
#define RAIDKM_MAX_STRIPE_DISKS	255

/*
 *
 * Each stripe contains one buffer per device.  Each buffer can be in
 * one of a number of states stored in "flags".  Changes between
 * these states happen *almost* exclusively under the protection of the
 * STRIPE_ACTIVE flag.  Some very specific changes can happen in bi_end_io, and
 * these are not protected by STRIPE_ACTIVE.
 *
 * The flag bits that are used to represent these states are:
 *   R5_UPTODATE and R5_LOCKED
 *
 * State Empty == !UPTODATE, !LOCK
 *        We have no data, and there is no active request
 * State Want == !UPTODATE, LOCK
 *        A read request is being submitted for this block
 * State Dirty == UPTODATE, LOCK
 *        Some new data is in this buffer, and it is being written out
 * State Clean == UPTODATE, !LOCK
 *        We have valid data which is the same as on disc
 *
 * The possible state transitions are:
 *
 *  Empty -> Want   - on read or write to get old data for  parity calc
 *  Empty -> Dirty  - on compute_parity to satisfy write/sync request.
 *  Empty -> Clean  - on compute_block when computing a block for failed drive
 *  Want  -> Empty  - on failed read
 *  Want  -> Clean  - on successful completion of read request
 *  Dirty -> Clean  - on successful completion of write request
 *  Dirty -> Clean  - on failed write
 *  Clean -> Dirty  - on compute_parity to satisfy write/sync (RECONSTRUCT or RMW)
 *
 * The Want->Empty, Want->Clean, Dirty->Clean, transitions
 * all happen in b_end_io at interrupt time.
 * Each sets the Uptodate bit before releasing the Lock bit.
 * This leaves one multi-stage transition:
 *    Want->Dirty->Clean
 * This is safe because thinking that a Clean buffer is actually dirty
 * will at worst delay some action, and the stripe will be scheduled
 * for attention after the transition is complete.
 *
 * There is one possibility that is not covered by these states.  That
 * is if one drive has failed and there is a spare being rebuilt.  We
 * can't distinguish between a clean block that has been generated
 * from parity calculations, and a clean block that has been
 * successfully written to the spare ( or to parity when resyncing).
 * To distinguish these states we have a stripe bit STRIPE_INSYNC that
 * is set whenever a write is scheduled to the spare, or to the parity
 * disc if there is no spare.  A sync request clears this bit, and
 * when we find it set with no buffers locked, we know the sync is
 * complete.
 *
 * Buffers for the md device that arrive via make_request are attached
 * to the appropriate stripe in one of two lists linked on b_reqnext.
 * One list (bh_read) for read requests, one (bh_write) for write.
 * There should never be more than one buffer on the two lists
 * together, but we are not guaranteed of that so we allow for more.
 *
 * If a buffer is on the read list when the associated cache buffer is
 * Uptodate, the data is copied into the read buffer and it's b_end_io
 * routine is called.  This may happen in the end_request routine only
 * if the buffer has just successfully been read.  end_request should
 * remove the buffers from the list and then set the Uptodate bit on
 * the buffer.  Other threads may do this only if they first check
 * that the Uptodate bit is set.  Once they have checked that they may
 * take buffers off the read queue.
 *
 * When a buffer on the write list is committed for write it is copied
 * into the cache buffer, which is then marked dirty, and moved onto a
 * third list, the written list (bh_written).  Once both the parity
 * block and the cached buffer are successfully written, any buffer on
 * a written list can be returned with b_end_io.
 *
 * The write list and read list both act as fifos.  The read list,
 * write list and written list are protected by the device_lock.
 * The device_lock is only for list manipulations and will only be
 * held for a very short time.  It can be claimed from interrupts.
 *
 *
 * Stripes in the stripe cache can be on one of two lists (or on
 * neither).  The "inactive_list" contains stripes which are not
 * currently being used for any request.  They can freely be reused
 * for another stripe.  The "handle_list" contains stripes that need
 * to be handled in some way.  Both of these are fifo queues.  Each
 * stripe is also (potentially) linked to a hash bucket in the hash
 * table so that it can be found by sector number.  Stripes that are
 * not hashed must be on the inactive_list, and will normally be at
 * the front.  All stripes start life this way.
 *
 * The inactive_list, handle_list and hash bucket lists are all protected by the
 * device_lock.
 *  - stripes have a reference counter. If count==0, they are on a list.
 *  - If a stripe might need handling, STRIPE_HANDLE is set.
 *  - When refcount reaches zero, then if STRIPE_HANDLE it is put on
 *    handle_list else inactive_list
 *
 * This, combined with the fact that STRIPE_HANDLE is only ever
 * cleared while a stripe has a non-zero count means that if the
 * refcount is 0 and STRIPE_HANDLE is set, then it is on the
 * handle_list and if recount is 0 and STRIPE_HANDLE is not set, then
 * the stripe is on inactive_list.
 *
 * The possible transitions are:
 *  activate an unhashed/inactive stripe (get_active_stripe())
 *     lockdev check-hash unlink-stripe cnt++ clean-stripe hash-stripe unlockdev
 *  activate a hashed, possibly active stripe (get_active_stripe())
 *     lockdev check-hash if(!cnt++)unlink-stripe unlockdev
 *  attach a request to an active stripe (add_stripe_bh())
 *     lockdev attach-buffer unlockdev
 *  handle a stripe (handle_stripe())
 *     setSTRIPE_ACTIVE,  clrSTRIPE_HANDLE ...
 *		(lockdev check-buffers unlockdev) ..
 *		change-state ..
 *		record io/ops needed clearSTRIPE_ACTIVE schedule io/ops
 *  release an active stripe (release_stripe())
 *     lockdev if (!--cnt) { if  STRIPE_HANDLE, add to handle_list else add to inactive-list } unlockdev
 *
 * The refcount counts each thread that have activated the stripe,
 * plus raid5d if it is handling it, plus one for each active request
 * on a cached buffer, and plus one if the stripe is undergoing stripe
 * operations.
 *
 * The stripe operations are:
 * -copying data between the stripe cache and user application buffers
 * -computing blocks to save a disk access, or to recover a missing block
 * -updating the parity on a write operation (reconstruct write and
 *  read-modify-write)
 * -checking parity correctness
 * -running i/o to disk
 * These operations are carried out by raid5_run_ops which uses the async_tx
 * api to (optionally) offload operations to dedicated hardware engines.
 * When requesting an operation handle_stripe sets the pending bit for the
 * operation and increments the count.  raid5_run_ops is then run whenever
 * the count is non-zero.
 * There are some critical dependencies between the operations that prevent some
 * from being requested while another is in flight.
 * 1/ Parity check operations destroy the in cache version of the parity block,
 *    so we prevent parity dependent operations like writes and compute_blocks
 *    from starting while a check is in progress.  Some dma engines can perform
 *    the check without damaging the parity block, in these cases the parity
 *    block is re-marked up to date (assuming the check was successful) and is
 *    not re-read from disk.
 * 2/ When a write operation is requested we immediately lock the affected
 *    blocks, and mark them as not up to date.  This causes new read requests
 *    to be held off, as well as parity checks and compute block operations.
 * 3/ Once a compute block operation has been requested handle_stripe treats
 *    that block as if it is up to date.  raid5_run_ops guaruntees that any
 *    operation that is dependent on the compute block result is initiated after
 *    the compute block completes.
 */

/*
 * Operations state - intermediate states that are visible outside of
 *   STRIPE_ACTIVE.
 * In general _idle indicates nothing is running, _run indicates a data
 * processing operation is active, and _result means the data processing result
 * is stable and can be acted upon.  For simple operations like biofill and
 * compute that only have an _idle and _run state they are indicated with
 * sh->state flags (STRIPE_BIOFILL_RUN and STRIPE_COMPUTE_RUN)
 */
/**
 * enum check_states - handles syncing / repairing a stripe
 * @check_state_idle - check operations are quiesced
 * @check_state_run - check operation is running
 * @check_state_result - set outside lock when check result is valid
 * @check_state_compute_run - check failed and we are repairing
 * @check_state_compute_result - set outside lock when compute result is valid
 */
enum check_states {
	check_state_idle = 0,
	check_state_run, /* xor parity check */
	check_state_run_q, /* q-parity check */
	check_state_run_pq, /* pq dual parity check */
	check_state_check_result,
	check_state_compute_run, /* parity repair */
	check_state_compute_result,
};

/**
 * enum reconstruct_states - handles writing or expanding a stripe
 */
enum reconstruct_states {
	reconstruct_state_idle = 0,
	reconstruct_state_prexor_drain_run,	/* prexor-write */
	reconstruct_state_drain_run,		/* write */
	reconstruct_state_run,			/* expand */
	reconstruct_state_prexor_drain_result,
	reconstruct_state_drain_result,
	reconstruct_state_result,
};

#define DEFAULT_STRIPE_SIZE	4096
struct stripe_head {
	/*
	 * Hot fields: accessed on every stripe operation.
	 * Kept in cache line 0 (offsets 0-63) so a single cache line fetch
	 * covers the lock, state, sector, and geometry.
	 */
	atomic_t		count;		/* nr of active thread/requests */
	unsigned long		state;		/* state flags */
	spinlock_t		stripe_lock;
	int			disks;		/* disks in stripe */
	sector_t		sector;		/* sector of this row */
	short			pd_idx;		/* parity disk index */
	short			qd_idx;		/* 'Q' disk index for raid6 */
	short			ddf_layout;	/* use DDF ordering to calculate Q */
	short			hash_lock_index;
	int			cpu;
	int			bm_seq;		/* sequence number for bitmap flushes */
	struct r5conf		*raid_conf;
	struct r5worker_group	*group;

	/*
	 * Warm fields: accessed during stripe processing but not on every
	 * lookup.
	 */
	short			generation;	/* increments with every reshape */
	int			overwrite_disks; /* total overwrite disks in stripe,
						  * this is only checked when stripe
						  * has STRIPE_BATCH_READY
						  */
	enum check_states	check_state;
	enum reconstruct_states reconstruct_state;
	struct stripe_head	*batch_head; /* protected by stripe lock */
	spinlock_t		batch_lock; /* only header's lock is useful */
	struct list_head	batch_list; /* protected by head's batch lock*/

	/**
	 * struct stripe_operations
	 * @target - STRIPE_OP_COMPUTE_BLK target
	 * @target2 - 2nd compute target in the raid6 case
	 * @zero_sum_result - P and Q verification flags
	 * @request - async service request flags for raid_run_ops
	 */
	struct stripe_operations {
		int		     target, target2;
		enum sum_check_flags zero_sum_result;
	} ops;

	/*
	 * Cold fields: hash/list management and journal/log.
	 * Pushed past the hot cache lines so handle_stripe doesn't
	 * evict useful data loading these.
	 */
	struct hlist_node	hash;
	struct list_head	lru;	      /* inactive_list or handle_list */
	struct llist_node	release_list;

	union {
		struct r5l_io_unit	*log_io;
		struct ppl_io_unit	*ppl_io;
	};

	struct list_head	log_list;
	sector_t		log_start; /* first meta block on the journal */
	struct list_head	r5c; /* for r5c_cache->stripe_in_journal */

	/*
	 * Partial parity of this stripe.  raid_km closes the write hole for
	 * arbitrary m by logging ALL m partial parities (raid5 PPL logs the
	 * single XOR parity); ppl_pages[0..m-1] hold them, one page each.
	 * ppl_pages[0] doubles as the raid5 single-page slot.
	 */
	struct page		*ppl_pages[RAIDKM_MAX_M];

#if PAGE_SIZE != DEFAULT_STRIPE_SIZE
	/* These pages will be used by bios in dev[i] */
	struct page	**pages;
	int	nr_pages;	/* page array size */
	int	stripes_per_page;
#endif
	struct r5dev {
		/* rreq and rvec are used for the replacement device when
		 * writing data to both devices.
		 */
		struct bio	req, rreq;
		struct bio_vec	vec, rvec;
		struct page	*page, *orig_page;
		unsigned int    offset;     /* offset of the page */
		struct bio	*toread, *read, *towrite, *written;
		sector_t	sector;			/* sector of this page */
		unsigned long	flags;
		u32		log_checksum;
		unsigned short	write_hint;
	} dev[]; /* allocated depending of RAID geometry ("disks" member) */
};

/* stripe_head_state - collects and tracks the dynamic state of a stripe_head
 *     for handle_stripe.
 */
struct stripe_head_state {
	/* 'syncing' means that we need to read all devices, either
	 * to check/correct parity, or to reconstruct a missing device.
	 * 'replacing' means we are replacing one or more drives and
	 * the source is valid at this point so we don't need to
	 * read all devices, just the replacement targets.
	 */
	int syncing, expanding, expanded, replacing;
	int locked, uptodate, to_read, to_write, failed, written;
	int to_fill, compute, req_compute, non_overwrite;
	int injournal, just_cached;
	/* raidkm m > 2 can lose up to m disks and still reconstruct, so the
	 * failed-slot list must hold RAIDKM_MAX_M entries (>= the raid5/6 2). */
	int failed_num[RAIDKM_MAX_M];
	int p_failed, q_failed;
	int dec_preread_active;
	unsigned long ops_request;

	struct md_rdev *blocked_rdev;
	int handle_bad_blocks;
	int log_failed;
	int waiting_extra_page;
};

/* Flags for struct r5dev.flags */
enum r5dev_flags {
	R5_UPTODATE,	/* page contains current data */
	R5_LOCKED,	/* IO has been submitted on "req" */
	R5_DOUBLE_LOCKED,/* Cannot clear R5_LOCKED until 2 writes complete */
	R5_OVERWRITE,	/* towrite covers whole page */
/* and some that are internal to handle_stripe */
	R5_Insync,	/* rdev && rdev->in_sync at start */
	R5_Wantread,	/* want to schedule a read */
	R5_Wantwrite,
	R5_Overlap,	/* There is a pending overlapping request
			 * on this block */
	R5_ReadNoMerge, /* prevent bio from merging in block-layer */
	R5_ReadError,	/* seen a read error here recently */
	R5_ReWrite,	/* have tried to over-write the readerror */

	R5_Expanded,	/* This block now has post-expand data */
	R5_Wantcompute,	/* compute_block in progress treat as
			 * uptodate
			 */
	R5_Wantfill,	/* dev->toread contains a bio that needs
			 * filling
			 */
	R5_Wantdrain,	/* dev->towrite needs to be drained */
	R5_WantFUA,	/* Write should be FUA */
	R5_SyncIO,	/* The IO is sync */
	R5_WriteError,	/* got a write error - need to record it */
	R5_MadeGood,	/* A bad block has been fixed by writing to it */
	R5_ReadRepl,	/* Will/did read from replacement rather than orig */
	R5_MadeGoodRepl,/* A bad block on the replacement device has been
			 * fixed by writing to it */
	R5_NeedReplace,	/* This device has a replacement which is not
			 * up-to-date at this stripe. */
	R5_WantReplace, /* We need to update the replacement, we have read
			 * data in, and now is a good time to write it out.
			 */
	R5_Discard,	/* Discard the stripe */
	R5_SkipCopy,	/* Don't copy data from bio to stripe cache */
	R5_InJournal,	/* data being written is in the journal device.
			 * if R5_InJournal is set for parity pd_idx, all the
			 * data and parity being written are in the journal
			 * device
			 */
	R5_OrigPageUPTDODATE,	/* with write back cache, we read old data into
				 * dev->orig_page for prexor. When this flag is
				 * set, orig_page contains latest data in the
				 * raid disk.
				 */
};

/*
 * Stripe state
 */
enum {
	STRIPE_ACTIVE,
	STRIPE_HANDLE,
	STRIPE_SYNC_REQUESTED,
	STRIPE_SYNCING,
	STRIPE_INSYNC,
	STRIPE_REPLACED,
	STRIPE_PREREAD_ACTIVE,
	STRIPE_DELAYED,
	STRIPE_DEGRADED,
	STRIPE_BIT_DELAY,
	STRIPE_EXPANDING,
	STRIPE_EXPAND_SOURCE,
	STRIPE_EXPAND_READY,
	STRIPE_IO_STARTED,	/* do not count towards 'bypass_count' */
	STRIPE_FULL_WRITE,	/* all blocks are set to be overwritten */
	STRIPE_BIOFILL_RUN,
	STRIPE_COMPUTE_RUN,
	STRIPE_ON_UNPLUG_LIST,
	STRIPE_DISCARD,
	STRIPE_ON_RELEASE_LIST,
	STRIPE_ON_INACTIVE_LIST,	/* sh->lru is on inactive_list[hash] —
					 * set under hash_locks[hash] in
					 * release_inactive_stripe_list() right
					 * before the splice; cleared by
					 * get_free_stripe / find_get_stripe
					 * fast-rescue when we pull off the
					 * inactive list */
	STRIPE_BATCH_READY,
	STRIPE_BATCH_ERR,
	STRIPE_BITMAP_PENDING,	/* Being added to bitmap, don't add
				 * to batch yet.
				 */
	STRIPE_LOG_TRAPPED,	/* trapped into log (see raid5-cache.c)
				 * this bit is used in two scenarios:
				 *
				 * 1. write-out phase
				 *  set in first entry of r5l_write_stripe
				 *  clear in second entry of r5l_write_stripe
				 *  used to bypass logic in handle_stripe
				 *
				 * 2. caching phase
				 *  set in r5c_try_caching_write()
				 *  clear when journal write is done
				 *  used to initiate r5c_cache_data()
				 *  also used to bypass logic in handle_stripe
				 */
	STRIPE_R5C_CACHING,	/* the stripe is in caching phase
				 * see more detail in the raid5-cache.c
				 */
	STRIPE_R5C_PARTIAL_STRIPE,	/* in r5c cache (to-be/being handled or
					 * in conf->r5c_partial_stripe_list)
					 */
	STRIPE_R5C_FULL_STRIPE,	/* in r5c cache (to-be/being handled or
				 * in conf->r5c_full_stripe_list)
				 */
	STRIPE_R5C_PREFLUSH,	/* need to flush journal device */
};

#define STRIPE_EXPAND_SYNC_FLAGS \
	((1 << STRIPE_EXPAND_SOURCE) |\
	(1 << STRIPE_EXPAND_READY) |\
	(1 << STRIPE_EXPANDING) |\
	(1 << STRIPE_SYNC_REQUESTED))
/*
 * Operation request flags
 */
enum {
	STRIPE_OP_BIOFILL,
	STRIPE_OP_COMPUTE_BLK,
	STRIPE_OP_PREXOR,
	STRIPE_OP_BIODRAIN,
	STRIPE_OP_RECONSTRUCT,
	STRIPE_OP_CHECK,
	STRIPE_OP_PARTIAL_PARITY,
};

/*
 * RAID parity calculation preferences
 */
enum {
	PARITY_DISABLE_RMW = 0,
	PARITY_ENABLE_RMW,
	PARITY_PREFER_RMW,
};

/*
 * Pages requested from set_syndrome_sources()
 */
enum {
	SYNDROME_SRC_ALL,
	SYNDROME_SRC_WANT_DRAIN,
	SYNDROME_SRC_WRITTEN,
};
/*
 * Plugging:
 *
 * To improve write throughput, we need to delay the handling of some
 * stripes until there has been a chance that several write requests
 * for the one stripe have all been collected.
 * In particular, any write request that would require pre-reading
 * is put on a "delayed" queue until there are no stripes currently
 * in a pre-read phase.  Further, if the "delayed" queue is empty when
 * a stripe is put on it then we "plug" the queue and do not process it
 * until an unplug call is made. (the unplug_io_fn() is called).
 *
 * When preread is initiated on a stripe, we set PREREAD_ACTIVE and add
 * it to the count of prereading stripes.
 * When write is initiated, or the stripe refcnt == 0 (just in case) we
 * clear the PREREAD_ACTIVE flag and decrement the count
 * Whenever the 'handle' queue is empty and the device is not plugged, we
 * move any strips from delayed to handle and clear the DELAYED flag and set
 * PREREAD_ACTIVE.
 * In stripe_handle, if we find pre-reading is necessary, we do it if
 * PREREAD_ACTIVE is set, else we set DELAYED which will send it to the delayed queue.
 * HANDLE gets cleared if stripe_handle leaves nothing locked.
 */

/* Note: disk_info.rdev can be set to NULL asynchronously by raid5_remove_disk.
 * There are three safe ways to access disk_info.rdev.
 * 1/ when holding mddev->reconfig_mutex
 * 2/ when resync/recovery/reshape is known to be happening - i.e. in code that
 *    is called as part of performing resync/recovery/reshape.
 * 3/ while holding rcu_read_lock(), use rcu_dereference to get the pointer
 *    and if it is non-NULL, increment rdev->nr_pending before dropping the RCU
 *    lock.
 * When .rdev is set to NULL, the nr_pending count checked again and if
 * it has been incremented, the pointer is put back in .rdev.
 */

struct disk_info {
	struct md_rdev	*rdev;
	struct md_rdev	*replacement;
	struct page	*extra_page; /* extra page to use in prexor */
};

/*
 * Stripe cache
 */

#define NR_STRIPES		256
/* Maximum stripe cache size.  32768 (the old limit) caps at ~32GB on typical
 * arrays; raise to 262144 to support up to ~256GB on large-RAM systems.
 */
#define RAID5_MAX_NR_STRIPES	262144U

#if PAGE_SIZE == DEFAULT_STRIPE_SIZE
#define STRIPE_SIZE		PAGE_SIZE
#define STRIPE_SHIFT		(PAGE_SHIFT - 9)
#define STRIPE_SECTORS		(STRIPE_SIZE>>9)
#endif

#define	IO_THRESHOLD		1
#define BYPASS_THRESHOLD	1
#define NR_HASH			(PAGE_SIZE / sizeof(struct hlist_head))
#define HASH_MASK		(NR_HASH - 1)
#define MAX_STRIPE_BATCH	8	/* stripes per handle_active_stripes pass;
					 * also the worker-spawn divisor.  Measured
					 * 2026-06-24: raising to 32 only helps deep
					 * queues (QD > 32*gtc) and is a ~2x loss on
					 * moderate queues -- keep coupled at 8. */
#define RAID5_SYNC_WINDOW	128	/* stripes to pre-submit per sync_request call */
#define RAID5_SYNC_HWMARK	2	/* rebuild uses at most 1/N of stripe cache */

/* NOTE NR_STRIPE_HASH_LOCKS must remain below 64.
 * This is because we sometimes take all the spinlocks
 * and creating that much locking depth can cause
 * problems.
 */
#define NR_STRIPE_HASH_LOCKS 32
#define STRIPE_HASH_LOCKS_MASK (NR_STRIPE_HASH_LOCKS - 1)

struct r5worker {
	struct work_struct work;
	struct r5worker_group *group;
	struct list_head temp_inactive_list[NR_STRIPE_HASH_LOCKS];
	bool working;
};

struct r5worker_group {
	struct list_head handle_list;
	struct list_head loprio_list;
	struct r5conf *conf;
	struct r5worker *workers;
	int stripes_cnt;
};

/*
 * r5c journal modes of the array: write-back or write-through.
 * write-through mode has identical behavior as existing log only
 * implementation.
 */
enum r5c_journal_mode {
	R5C_JOURNAL_MODE_WRITE_THROUGH = 0,
	R5C_JOURNAL_MODE_WRITE_BACK = 1,
};

enum r5_cache_state {
	R5_INACTIVE_BLOCKED,	/* release of inactive stripes blocked,
				 * waiting for 25% to be free
				 */
	R5_ALLOC_MORE,		/* It might help to allocate another
				 * stripe.
				 */
	R5_DID_ALLOC,		/* A stripe was allocated, don't allocate
				 * more until at least one has been
				 * released.  This avoids flooding
				 * the cache.
				 */
	R5C_LOG_TIGHT,		/* log device space tight, need to
				 * prioritize stripes at last_checkpoint
				 */
	R5C_LOG_CRITICAL,	/* log device is running out of space,
				 * only process stripes that are already
				 * occupying the log
				 */
	R5C_EXTRA_PAGE_IN_USE,	/* a stripe is using disk_info.extra_page
				 * for prexor
				 */
};

#define PENDING_IO_MAX 512
#define PENDING_IO_ONE_FLUSH 128
struct r5pending_data {
	struct list_head sibling;
	sector_t sector; /* stripe sector */
	struct bio_list bios;
};

struct raid5_percpu {
	struct page	*spare_page; /* Used when checking P/Q in raid6 */
	void		*scribble;  /* space for constructing buffer
				     * lists and performing address
				     * conversions
				     */
	int             scribble_obj_size;
	void		*km_decode; /* raidkm: per-cpu scratch for the synchronous
				     * decode in ops_run_compute_km (b/inv/dtbls1/
				     * row1, ~3 KiB) — kept off the kernel stack.
				     * See struct raidkm_decode_scratch.
				     */
	local_lock_t    lock;
};

struct r5conf {
	struct hlist_head	*stripe_hashtbl;
	/* only protect corresponding hash list and inactive_list */
	spinlock_t		hash_locks[NR_STRIPE_HASH_LOCKS];
	struct mddev		*mddev;
	unsigned int		chunk_sectors;
	int			level, algorithm, rmw_level;
	/*
	 * raid_km redesign: effective_level is what internal
	 * "want raid6 math" checks should look at.  For stock
	 * raid4/5/6 it equals level.  For raid_km (level 71) it is
	 * 6, so the verbatim raid5.c logic that hardcodes "level ==
	 * 6" for Q-disk handling fires correctly without our having
	 * to mutate mddev->level (which md core treats as
	 * invariant after md_run).
	 */
	int			effective_level;
	/*
	 * raid_km redesign: parity count.  For raidkm (level 71) m is
	 * derived from mddev->layout at create time and must be >= 2.
	 * For stock raid4/5/6 m mirrors max_degraded (1, 1, 2).
	 *
	 * When m == 2, the verbatim raid5.c paths (raid6_call P+Q math)
	 * are reused as in the rest of the redesign.  When m > 2 the
	 * EC encode/decode runs through ISA-L's ec_encode_data_* via
	 * the encoding table built in setup_conf.  The I/O path for
	 * m > 2 lands in a follow-up commit; this commit only plumbs
	 * the configuration through.
	 */
	int			m;
	/*
	 * raid_km redesign: parity-placement layout.  false = fixed PARITY_N
	 * (data slots [0,k), parity at [k,k+m)); true = rotating parity
	 * (generalized left-symmetric: the m-slot parity block rotates one
	 * disk per stripe so parity — and reads — spread across all members).
	 * Derived from RAIDKM_LAYOUT_ROTATING in mddev->layout at create time.
	 * Both layouts share one slot-mapping (raidkm_data_slot/parity_slot);
	 * PARITY_N is the special case pd_idx == k.
	 */
	bool			rotating;
	/*
	 * ISA-L encoding state for m > 2.  ec_a_matrix is the full
	 * (k + m) x k generator matrix from gf_gen_rs_matrix; only the
	 * last m rows are encoding rows.  ec_g_tbls_gfni and
	 * ec_g_tbls_base are each m * k * 32 bytes.  GFNI-format tables
	 * feed ec_encode_data_*_gfni; base-format tables feed
	 * ec_encode_data_base on hosts without GFNI.  Both are built
	 * because the two formats are NOT interchangeable.  NULL for
	 * m == 2.
	 */
	unsigned char		*ec_a_matrix;
	unsigned char		*ec_g_tbls_gfni;
	unsigned char		*ec_g_tbls_base;
	/*
	 * During an online grow/shrink reshape the data-disk count k changes,
	 * so the EC matrix/tables above are rebuilt for the NEW k and the
	 * PREVIOUS-k set is kept here until the reshape finishes.  Both
	 * geometries are live concurrently (I/O to pre- vs post-reshape_position
	 * stripes), selected per call by k via raidkm_a_matrix()/raidkm_g_*().
	 * NULL when not reshaping.
	 */
	unsigned char		*prev_ec_a_matrix;
	unsigned char		*prev_ec_g_tbls_gfni;
	unsigned char		*prev_ec_g_tbls_base;
	/*
	 * Parity count of the previous (not-yet-reshaped) geometry.  Equals
	 * conf->m except during an add-parity reshape, when the before-region
	 * still uses prev_m parities and the after-region uses m.  Selected per
	 * stripe by raidkm_sh_m().  Kept == m at all other times.
	 */
	int			prev_m;
#ifdef RAIDKM_FAULT_INJECT
	/* Debug fault-injection state for the COW reshape (raidkm_reshape_inject
	 * sysfs knob; only present in RAIDKM_FAULT_INJECT=1 builds). */
	struct raidkm_reshape_inject	reshape_inject;
#endif
	int			max_degraded;
	int			raid_disks;
	unsigned int		max_nr_stripes;
	unsigned int		min_nr_stripes;
#if PAGE_SIZE != DEFAULT_STRIPE_SIZE
	unsigned long	stripe_size;
	unsigned int	stripe_shift;
	unsigned long	stripe_sectors;
#endif

	/* reshape_progress is the leading edge of a 'reshape'
	 * It has value MaxSector when no reshape is happening
	 * If delta_disks < 0, it is the last sector we started work on,
	 * else is it the next sector to work on.
	 */
	sector_t		reshape_progress;
	/* reshape_safe is the trailing edge of a reshape.  We know that
	 * before (or after) this address, all reshape has completed.
	 */
	sector_t		reshape_safe;
	int			previous_raid_disks;
	unsigned int		prev_chunk_sectors;
	int			prev_algo;
	short			generation; /* increments with every reshape */
	seqcount_spinlock_t	gen_lock;	/* lock against generation changes */
	unsigned long		reshape_checkpoint; /* Time we last updated
						     * metadata */
	long long		min_offset_diff; /* minimum difference between
						  * data_offset and
						  * new_data_offset across all
						  * devices.  May be negative,
						  * but is closest to zero.
						  */

	struct list_head	handle_list; /* stripes needing handling */
	struct list_head	loprio_list; /* low priority stripes */
	struct list_head	hold_list; /* preread ready stripes */
	struct list_head	delayed_list; /* stripes that have plugged requests */
	struct list_head	bitmap_list; /* stripes delaying awaiting bitmap update */
	struct bio		*retry_read_aligned; /* currently retrying aligned bios   */
	unsigned int		retry_read_offset; /* sector offset into retry_read_aligned */
	struct bio		*retry_read_aligned_list; /* aligned bios retry list  */
	atomic_t		preread_active_stripes; /* stripes with scheduled io */
	atomic_t		active_aligned_reads;
	atomic_t		pending_full_writes; /* full write backlog */
	int			bypass_count; /* bypassed prereads */
	int			bypass_threshold; /* preread nice */
	int			skip_copy; /* Don't copy data from bio to stripe cache */
	struct list_head	*last_hold; /* detect hold_list promotions */

	atomic_t		reshape_stripes; /* stripes with pending writes for reshape */
	/* unfortunately we need two cache names as we temporarily have
	 * two caches.
	 */
	int			active_name;
	char			cache_name[2][32];
	struct kmem_cache	*slab_cache; /* for allocating stripes */
	struct mutex		cache_size_mutex; /* Protect changes to cache size */

	int			seq_flush, seq_write;
	int			quiesce;

	int			fullsync;  /* set to 1 if a full sync is needed,
					    * (fresh device added).
					    * Cleared when a sync completes.
					    */
	int			recovery_disabled;
	/* per cpu variables */
	struct raid5_percpu __percpu *percpu;
	int scribble_disks;
	int scribble_sectors;
	struct hlist_node node;

	/*
	 * Free stripes pool
	 */
	atomic_t		active_stripes;
	struct list_head	inactive_list[NR_STRIPE_HASH_LOCKS];

	atomic_t		r5c_cached_full_stripes;
	struct list_head	r5c_full_stripe_list;
	atomic_t		r5c_cached_partial_stripes;
	struct list_head	r5c_partial_stripe_list;
	atomic_t		r5c_flushing_full_stripes;
	atomic_t		r5c_flushing_partial_stripes;

	atomic_t		empty_inactive_list_nr;

	/*
	 * raid_km self-healing telemetry: count of blocks that were
	 * located as corrupt/unreadable (e.g. an integrity layer flagged
	 * silent corruption -> read error) and repaired by reconstructing
	 * from parity and rewriting the corrected block.  Distinct from
	 * mddev->resync_mismatches (parity inconsistencies).  Exposed
	 * read-only via the "healed_blocks" sysfs attribute.
	 *
	 * Coverage: read-path heals (any m, via the handle_stripe
	 * R5_ReadError rewrite) and m>2 scrub/repair heals (data via the
	 * same rewrite, parity via handle_parity_checks6).  m==2
	 * proactive-scrub heals that flow through the inherited stock raid6
	 * repair path (check_state_compute_result) are not separately
	 * counted -- raid6-equivalent, outside raidkm's m>2 differentiator.
	 */
	atomic64_t		healed_blocks;

	struct llist_head	released_stripes;
	wait_queue_head_t	wait_for_quiescent;
	wait_queue_head_t	wait_for_stripe;
	wait_queue_head_t	wait_for_reshape;
	unsigned long		cache_state;
	struct shrinker		*shrinker;
	int			pool_size; /* number of disks in stripeheads in pool */
	spinlock_t		device_lock;
	struct disk_info	*disks;
	struct bio_set		bio_split;

	/* When taking over an array from a different personality, we store
	 * the new thread here until we fully activate the array.
	 */
	struct md_thread __rcu	*thread;
	struct list_head	temp_inactive_list[NR_STRIPE_HASH_LOCKS];
	struct r5worker_group	*worker_groups;
	int			group_cnt;
	int			worker_cnt_per_group;
	struct r5l_log		*log;
	void			*log_private;

	spinlock_t		pending_bios_lock;
	bool			batch_bio_dispatch;
	struct r5pending_data	*pending_data;
	struct list_head	free_list;
	struct list_head	pending_list;
	int			pending_data_cnt;
	struct r5pending_data	*next_pending_data;
};

/*
 * raid_km redesign helpers (shared by raid_km.c and raid_km-ppl.c, hence
 * here rather than file-static).
 *
 * is_raidkm() — this conf is a raidkm array (level 71).
 *
 * Slot mapping.  raidkm supports two parity-placement layouts behind one
 * formula.  Per stripe the m parity slots occupy pd_idx, pd_idx+1, ...,
 * pd_idx+m-1 (mod N); the k data slots follow, pd_idx+m .. pd_idx+m+k-1
 * (mod N), carrying logical data indices 0..k-1 in order:
 *
 *   raidkm_parity_slot(sh, j) — physical slot of parity index j (0..m-1)
 *   raidkm_data_slot(sh, d)   — physical slot of data index d (0..k-1)
 *   raidkm_data_index(sh, i)  — logical data index of a physical data slot i
 *   raidkm_matrix_row(sh, i)  — ec_a_matrix row for slot i (data row d, or
 *                               parity row k+j) — used by the decode
 *
 * For PARITY_N pd_idx == k (constant), so raidkm_data_slot(sh,d) == d and
 * raidkm_parity_slot(sh,j) == k+j — i.e. these reduce to the identity the
 * pre-rotating code assumed.  For rotating pd_idx varies per stripe; the
 * only layout-specific code is how compute_sector picks pd_idx.
 */
static inline bool is_raidkm(struct r5conf *conf)
{
	return conf->level == RAID_KM_LEVEL;
}

/*
 * raidkm_sh_m() — the parity count (m) for THIS stripe's geometry.  During an
 * add-parity reshape conf->prev_m != conf->m, and a before-region stripe (one
 * that still spans the previous disk count) uses the old m; the after-region
 * (and every non-reshape / fixed-m grow-data case, where prev_m == m) uses
 * conf->m.  sh->disks already carries the stripe's geometry, so it is the
 * region discriminator.  k for the stripe is always sh->disks - raidkm_sh_m().
 */
static inline int raidkm_sh_m(struct stripe_head *sh)
{
	struct r5conf *conf = sh->raid_conf;

	/*
	 * previous_raid_disks != raid_disks is the "two geometries live" guard:
	 * end_reshape() bumps previous_raid_disks up to raid_disks when the
	 * reshape finishes (before prev_m is reset), and without this guard a
	 * normal post-reshape stripe (sh->disks == raid_disks == prev) would be
	 * mis-read as the previous geometry and handed the stale m.
	 */
	if (conf->prev_m != conf->m &&
	    conf->previous_raid_disks != conf->raid_disks &&
	    sh->disks == conf->previous_raid_disks)
		return conf->prev_m;
	return conf->m;
}

static inline int raidkm_parity_slot(struct stripe_head *sh, int j)
{
	return (sh->pd_idx + j) % sh->disks;
}

static inline int raidkm_data_slot(struct stripe_head *sh, int d)
{
	return (sh->pd_idx + raidkm_sh_m(sh) + d) % sh->disks;
}

static inline int raidkm_data_index(struct stripe_head *sh, int slot)
{
	int rel = (slot - sh->pd_idx + sh->disks) % sh->disks;

	return rel - raidkm_sh_m(sh);	/* caller ensures slot is a data slot */
}

static inline int raidkm_matrix_row(struct stripe_head *sh, int slot)
{
	int rel = (slot - sh->pd_idx + sh->disks) % sh->disks;
	int m = raidkm_sh_m(sh);
	int k = sh->disks - m;

	if (rel < m)
		return k + rel;		/* parity index rel -> encode row k+rel */
	return rel - m;			/* data index -> identity row */
}

/*
 * is_parity_disk() — true for any parity disk in this stripe.  Stock
 * raid4/5/6 has parity at pd_idx (and qd_idx for raid6).  raidkm has m
 * parity slots starting at pd_idx and wrapping mod N; the modular test
 * below is correct for both PARITY_N (no wrap) and rotating (may wrap),
 * and degenerates to the stock raid6 pd_idx/qd_idx form at m == 2.
 */
static inline bool is_parity_disk(struct stripe_head *sh, int i)
{
	if (is_raidkm(sh->raid_conf)) {
		int rel = (i - sh->pd_idx + sh->disks) % sh->disks;

		return rel < raidkm_sh_m(sh);
	}
	return i == sh->pd_idx || i == sh->qd_idx;
}

/*
 * EC matrix/table selection for a given stripe.  Outside a reshape, prev_ec_*
 * are NULL and the current set is always returned.  During a reshape two
 * geometries are live concurrently; a stripe that still spans the previous
 * disk count (sh->disks == previous_raid_disks) is steered to the previous
 * tables, everything else to the current (new) tables.  Keying on the stripe's
 * region — not on k — is required for add-parity, where the data count k is
 * identical on both sides and only m (hence raid_disks) changes; it is equally
 * correct for grow-data, where the before-region's disk count differs anyway.
 *
 * The previous tables are only consulted while two distinct geometries are
 * actually live, i.e. previous_raid_disks != raid_disks.  end_reshape() bumps
 * previous_raid_disks up to raid_disks when the reshape finishes, BEFORE
 * raid5_finish_reshape() frees prev_ec_*; the reshape_live guard keeps a new
 * stripe in that window from being handed the stale previous tables.
 */
#define raidkm_reshape_live(conf) ((conf)->previous_raid_disks != (conf)->raid_disks)

static inline bool raidkm_sh_prev(struct stripe_head *sh)
{
	struct r5conf *conf = sh->raid_conf;

	return raidkm_reshape_live(conf) &&
	       sh->disks == conf->previous_raid_disks;
}

static inline unsigned char *raidkm_a_matrix(struct stripe_head *sh)
{
	struct r5conf *conf = sh->raid_conf;

	if (conf->prev_ec_a_matrix && raidkm_sh_prev(sh))
		return conf->prev_ec_a_matrix;
	return conf->ec_a_matrix;
}
static inline unsigned char *raidkm_g_gfni(struct stripe_head *sh)
{
	struct r5conf *conf = sh->raid_conf;

	if (conf->prev_ec_g_tbls_gfni && raidkm_sh_prev(sh))
		return conf->prev_ec_g_tbls_gfni;
	return conf->ec_g_tbls_gfni;
}
static inline unsigned char *raidkm_g_base(struct stripe_head *sh)
{
	struct r5conf *conf = sh->raid_conf;

	if (conf->prev_ec_g_tbls_base && raidkm_sh_prev(sh))
		return conf->prev_ec_g_tbls_base;
	return conf->ec_g_tbls_base;
}

#if PAGE_SIZE == DEFAULT_STRIPE_SIZE
#define RAID5_STRIPE_SIZE(conf)	STRIPE_SIZE
#define RAID5_STRIPE_SHIFT(conf)	STRIPE_SHIFT
#define RAID5_STRIPE_SECTORS(conf)	STRIPE_SECTORS
#else
#define RAID5_STRIPE_SIZE(conf)	((conf)->stripe_size)
#define RAID5_STRIPE_SHIFT(conf)	((conf)->stripe_shift)
#define RAID5_STRIPE_SECTORS(conf)	((conf)->stripe_sectors)
#endif

/* bio's attached to a stripe+device for I/O are linked together in bi_sector
 * order without overlap.  There may be several bio's per stripe+device, and
 * a bio could span several devices.
 * When walking this list for a particular stripe+device, we must never proceed
 * beyond a bio that extends past this device, as the next bio might no longer
 * be valid.
 * This function is used to determine the 'next' bio in the list, given the
 * sector of the current stripe+device
 */
static inline struct bio *r5_next_bio(struct r5conf *conf, struct bio *bio, sector_t sector)
{
	if (bio_end_sector(bio) < sector + RAID5_STRIPE_SECTORS(conf))
		return bio->bi_next;
	else
		return NULL;
}

/*
 * Our supported algorithms
 */
#define ALGORITHM_LEFT_ASYMMETRIC	0 /* Rotating Parity N with Data Restart */
#define ALGORITHM_RIGHT_ASYMMETRIC	1 /* Rotating Parity 0 with Data Restart */
#define ALGORITHM_LEFT_SYMMETRIC	2 /* Rotating Parity N with Data Continuation */
#define ALGORITHM_RIGHT_SYMMETRIC	3 /* Rotating Parity 0 with Data Continuation */

/* Define non-rotating (raid4) algorithms.  These allow
 * conversion of raid4 to raid5.
 */
#define ALGORITHM_PARITY_0		4 /* P or P,Q are initial devices */
#define ALGORITHM_PARITY_N		5 /* P or P,Q are final devices. */

/* DDF RAID6 layouts differ from md/raid6 layouts in two ways.
 * Firstly, the exact positioning of the parity block is slightly
 * different between the 'LEFT_*' modes of md and the "_N_*" modes
 * of DDF.
 * Secondly, or order of datablocks over which the Q syndrome is computed
 * is different.
 * Consequently we have different layouts for DDF/raid6 than md/raid6.
 * These layouts are from the DDFv1.2 spec.
 * Interestingly DDFv1.2-Errata-A does not specify N_CONTINUE but
 * leaves RLQ=3 as 'Vendor Specific'
 */

#define ALGORITHM_ROTATING_ZERO_RESTART	8 /* DDF PRL=6 RLQ=1 */
#define ALGORITHM_ROTATING_N_RESTART	9 /* DDF PRL=6 RLQ=2 */
#define ALGORITHM_ROTATING_N_CONTINUE	10 /*DDF PRL=6 RLQ=3 */

/* For every RAID5 algorithm we define a RAID6 algorithm
 * with exactly the same layout for data and parity, and
 * with the Q block always on the last device (N-1).
 * This allows trivial conversion from RAID5 to RAID6
 */
#define ALGORITHM_LEFT_ASYMMETRIC_6	16
#define ALGORITHM_RIGHT_ASYMMETRIC_6	17
#define ALGORITHM_LEFT_SYMMETRIC_6	18
#define ALGORITHM_RIGHT_SYMMETRIC_6	19
#define ALGORITHM_PARITY_0_6		20
#define ALGORITHM_PARITY_N_6		ALGORITHM_PARITY_N

static inline int algorithm_valid_raid5(int layout)
{
	return (layout >= 0) &&
		(layout <= 5);
}
static inline int algorithm_valid_raid6(int layout)
{
	return (layout >= 0 && layout <= 5)
		||
		(layout >= 8 && layout <= 10)
		||
		(layout >= 16 && layout <= 20);
}

static inline int algorithm_is_DDF(int layout)
{
	return layout >= 8 && layout <= 10;
}

#if PAGE_SIZE != DEFAULT_STRIPE_SIZE
/*
 * Return offset of the corresponding page for r5dev.
 */
static inline int raid5_get_page_offset(struct stripe_head *sh, int disk_idx)
{
	return (disk_idx % sh->stripes_per_page) * RAID5_STRIPE_SIZE(sh->raid_conf);
}

/*
 * Return corresponding page address for r5dev.
 */
static inline struct page *
raid5_get_dev_page(struct stripe_head *sh, int disk_idx)
{
	return sh->pages[disk_idx / sh->stripes_per_page];
}
#endif

void md_raid5_kick_device(struct r5conf *conf);
int raid_km_set_cache_size(struct mddev *mddev, int size);
sector_t raid5_compute_blocknr(struct stripe_head *sh, int i, int previous);
void raid5_release_stripe(struct stripe_head *sh);
sector_t raid5_compute_sector(struct r5conf *conf, sector_t r_sector,
		int previous, int *dd_idx, struct stripe_head *sh);

struct stripe_request_ctx;
/* get stripe from previous generation (when reshaping) */
#define R5_GAS_PREVIOUS		(1 << 0)
/* do not block waiting for a free stripe */
#define R5_GAS_NOBLOCK		(1 << 1)
/* do not block waiting for quiesce to be released */
#define R5_GAS_NOQUIESCE	(1 << 2)
struct stripe_head *raid5_get_active_stripe(struct r5conf *conf,
		struct stripe_request_ctx *ctx, sector_t sector,
		unsigned int flags);

int raid5_calc_degraded(struct r5conf *conf);
int raid_km_c_journal_mode_set(struct mddev *mddev, int journal_mode);
/* PPL: compute all m partial parities into sh->ppl_pages[] (raid_km.c) */
void raidkm_compute_partial_parity(struct stripe_head *sh);
/* PPL recovery: encode modified data into m parity pages (raid_km.c) */
void raidkm_ppl_encode_modified(struct r5conf *conf, void **src,
				void **cod, size_t bytes);
#endif
