// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (C) 2014 Facebook. All rights reserved.
 *
 * This file is released under the GPL.
 *
 * dm-log-writes-ord: drivers/md/dm-log-writes.c (Linux 7.1-rc2) changed to log
 * every write in the order it COMPLETED, for the raidkm power-cut harness
 * (tools/raidkm-test-powercut.sh).  Target "log-writes-ord", log version 2.
 *
 * Why: dm-log-writes takes the writes completed so far into a flush's group
 * when the flush is MAPPED, and logs the group when the flush COMPLETES.  A
 * flush that is mapped and then waits before it reaches the device (a request
 * tag, preemption) can complete after a flush mapped later, so the later
 * group -- writes that completed after the earlier group's -- is logged first.
 * Two writes to one sector then replay in the wrong order: a crash state no
 * device can produce (the harness read it as data loss: block 39186, 11-07).
 *
 * Here a write is logged when it completes, and a flush logs two entries: a
 * FLUSH_START entry when it is mapped and its FLUSH entry when it completes,
 * both carrying the same 64-bit id as their data.  The writes logged before a
 * flush's FLUSH_START are the ones that flush made durable once its FLUSH
 * entry is in the log -- what the original's group was, now without the
 * reordering.  FUA writes are durable when they are logged, as before.  A
 * write or flush that completed with an error carries LOG_ERROR_FLAG (no
 * durability); one dm requeues is logged when it completes the second time.
 *
 * Also left out: DAX, the ioctl pass-through, and the logging of discards a
 * device cannot take (the harness's members all take them), so that one file
 * builds against the RHEL 9 and RHEL 10 kernels as well as current ones.
 */

#include <linux/device-mapper.h>

#include <linux/module.h>
#include <linux/init.h>
#include <linux/blkdev.h>
#include <linux/bio.h>
#include <linux/slab.h>
#include <linux/kthread.h>
#include <linux/freezer.h>
#include <linux/uio.h>

#define DM_MSG_PREFIX "log-writes-ord"

/*
 * This target will sequentially log all writes to the target device onto the
 * log device.  This is helpful for replaying writes to check for fs consistency
 * at all times.  This target provides a mechanism to mark specific events to
 * check data at a later time.  So for example you would:
 *
 * write data
 * fsync
 * dmsetup message /dev/whatever mark mymark
 * unmount /mnt/test
 *
 * Then replay the log up to mymark and check the contents of the replay to
 * verify it matches what was written.
 *
 * (The original logged a write only at the next flush that covered it; this
 * copy logs it at completion -- see the top of the file.)
 */
#define LOG_FLUSH_FLAG		(1 << 0)
#define LOG_FUA_FLAG		(1 << 1)
#define LOG_DISCARD_FLAG	(1 << 2)
#define LOG_MARK_FLAG		(1 << 3)
#define LOG_METADATA_FLAG	(1 << 4)
#define LOG_FLUSH_START_FLAG	(1 << 5)	/* a flush was mapped: data = its id */
#define LOG_ERROR_FLAG		(1 << 6)	/* completed with an error */

#define WRITE_LOG_VERSION 2ULL	/* 2: writes in completion order + FLUSH_START */
#define WRITE_LOG_MAGIC 0x6a736677736872ULL
#define WRITE_LOG_SUPER_SECTOR 0

/*
 * The disk format for this is braindead simple.
 *
 * At byte 0 we have our super, followed by the following sequence for
 * nr_entries:
 *
 * [   1 sector    ][  entry->nr_sectors ]
 * [log_write_entry][    data written    ]
 *
 * The log_write_entry takes up a full sector so we can have arbitrary length
 * marks and it leaves us room for extra content in the future.
 */

/*
 * Basic info about the log for userspace.
 */
struct log_write_super {
	__le64 magic;
	__le64 version;
	__le64 nr_entries;
	__le32 sectorsize;
};

/*
 * sector - the sector we wrote.
 * nr_sectors - the number of sectors we wrote.
 * flags - flags for this log entry.
 * data_len - the size of the data in this log entry, this is for private log
 * entry stuff, the MARK data provided by userspace for example.
 */
struct log_write_entry {
	__le64 sector;
	__le64 nr_sectors;
	__le64 flags;
	__le64 data_len;
};

struct log_writes_c {
	struct dm_dev *dev;
	struct dm_dev *logdev;
	u64 logged_entries;
	u32 sectorsize;
	u32 sectorshift;
	atomic_t io_blocks;
	atomic_t pending_blocks;
	sector_t next_sector;
	sector_t end_sector;
	bool logging_enabled;
	spinlock_t blocks_lock;
	u64 flush_seq;			/* last flush id, under blocks_lock */
	struct list_head logging_blocks;
	wait_queue_head_t wait;
	struct task_struct *log_kthread;
	struct completion super_done;
};

struct pending_block {
	int vec_cnt;
	u64 flags;
	sector_t sector;
	sector_t nr_sectors;
	char *data;
	u32 datalen;
	__le64 flush_id;	/* FLUSH / FLUSH_START: logged as the entry's data */
	struct list_head list;
	struct bio_vec vecs[];
};

struct per_bio_data {
	struct pending_block *block;
};

static inline sector_t bio_to_dev_sectors(struct log_writes_c *lc,
					  sector_t sectors)
{
	return sectors >> (lc->sectorshift - SECTOR_SHIFT);
}

static inline sector_t dev_to_bio_sectors(struct log_writes_c *lc,
					  sector_t sectors)
{
	return sectors << (lc->sectorshift - SECTOR_SHIFT);
}

static void put_pending_block(struct log_writes_c *lc)
{
	if (atomic_dec_and_test(&lc->pending_blocks)) {
		smp_mb__after_atomic();
		if (waitqueue_active(&lc->wait))
			wake_up(&lc->wait);
	}
}

static void put_io_block(struct log_writes_c *lc)
{
	if (atomic_dec_and_test(&lc->io_blocks)) {
		smp_mb__after_atomic();
		if (waitqueue_active(&lc->wait))
			wake_up(&lc->wait);
	}
}

static void log_end_io(struct bio *bio)
{
	struct log_writes_c *lc = bio->bi_private;

	if (bio->bi_status) {
		unsigned long flags;

		DMERR("Error writing log block, error=%d", bio->bi_status);
		spin_lock_irqsave(&lc->blocks_lock, flags);
		lc->logging_enabled = false;
		spin_unlock_irqrestore(&lc->blocks_lock, flags);
	}

	bio_free_pages(bio);
	put_io_block(lc);
	bio_put(bio);
}

static void log_end_super(struct bio *bio)
{
	struct log_writes_c *lc = bio->bi_private;

	complete(&lc->super_done);
	log_end_io(bio);
}

/*
 * Meant to be called if there is an error, it will free all the pages
 * associated with the block.
 */
static void free_pending_block(struct log_writes_c *lc,
			       struct pending_block *block)
{
	int i;

	for (i = 0; i < block->vec_cnt; i++) {
		if (block->vecs[i].bv_page)
			__free_page(block->vecs[i].bv_page);
	}
	kfree(block->data);
	kfree(block);
	put_pending_block(lc);
}

static int write_metadata(struct log_writes_c *lc, void *entry,
			  size_t entrylen, void *data, size_t datalen,
			  sector_t sector)
{
	struct bio *bio;
	struct page *page;
	void *ptr;
	size_t ret;

	bio = bio_alloc(lc->logdev->bdev, 1, REQ_OP_WRITE, GFP_KERNEL);
	bio->bi_iter.bi_size = 0;
	bio->bi_iter.bi_sector = sector;
	bio->bi_end_io = (sector == WRITE_LOG_SUPER_SECTOR) ?
			  log_end_super : log_end_io;
	bio->bi_private = lc;

	page = alloc_page(GFP_KERNEL);
	if (!page) {
		DMERR("Couldn't alloc log page");
		bio_put(bio);
		goto error;
	}

	ptr = kmap_local_page(page);
	memcpy(ptr, entry, entrylen);
	if (datalen)
		memcpy(ptr + entrylen, data, datalen);
	memset(ptr + entrylen + datalen, 0,
	       lc->sectorsize - entrylen - datalen);
	kunmap_local(ptr);

	ret = bio_add_page(bio, page, lc->sectorsize, 0);
	if (ret != lc->sectorsize) {
		DMERR("Couldn't add page to the log block");
		goto error_bio;
	}
	submit_bio(bio);
	return 0;
error_bio:
	bio_put(bio);
	__free_page(page);
error:
	put_io_block(lc);
	return -1;
}

static int write_inline_data(struct log_writes_c *lc, void *entry,
			     size_t entrylen, void *data, size_t datalen,
			     sector_t sector)
{
	int bio_pages, pg_datalen, pg_sectorlen, i;
	struct page *page;
	struct bio *bio;
	size_t ret;
	void *ptr;

	while (datalen) {
		bio_pages = bio_max_segs(DIV_ROUND_UP(datalen, PAGE_SIZE));

		atomic_inc(&lc->io_blocks);

		bio = bio_alloc(lc->logdev->bdev, bio_pages, REQ_OP_WRITE,
				GFP_KERNEL);
		bio->bi_iter.bi_size = 0;
		bio->bi_iter.bi_sector = sector;
		bio->bi_end_io = log_end_io;
		bio->bi_private = lc;

		for (i = 0; i < bio_pages; i++) {
			pg_datalen = min_t(int, datalen, PAGE_SIZE);
			pg_sectorlen = ALIGN(pg_datalen, lc->sectorsize);

			page = alloc_page(GFP_KERNEL);
			if (!page) {
				DMERR("Couldn't alloc inline data page");
				goto error_bio;
			}

			ptr = kmap_local_page(page);
			memcpy(ptr, data, pg_datalen);
			if (pg_sectorlen > pg_datalen)
				memset(ptr + pg_datalen, 0, pg_sectorlen - pg_datalen);
			kunmap_local(ptr);

			ret = bio_add_page(bio, page, pg_sectorlen, 0);
			if (ret != pg_sectorlen) {
				DMERR("Couldn't add page of inline data");
				__free_page(page);
				goto error_bio;
			}

			datalen -= pg_datalen;
			data	+= pg_datalen;
		}
		submit_bio(bio);

		sector += bio_pages * PAGE_SECTORS;
	}
	return 0;
error_bio:
	bio_free_pages(bio);
	bio_put(bio);
	put_io_block(lc);
	return -1;
}

static int log_one_block(struct log_writes_c *lc,
			 struct pending_block *block, sector_t sector)
{
	struct bio *bio;
	struct log_write_entry entry;
	size_t metadatalen, ret;
	int i;

	entry.sector = cpu_to_le64(block->sector);
	entry.nr_sectors = cpu_to_le64(block->nr_sectors);
	entry.flags = cpu_to_le64(block->flags);
	entry.data_len = cpu_to_le64(block->datalen);

	/* a mark's text and a flush's id go in the entry sector */
	metadatalen = (block->flags & LOG_MARK_FLAG) ? block->datalen : 0;
	if (block->flags & (LOG_FLUSH_FLAG | LOG_FLUSH_START_FLAG)) {
		entry.data_len = cpu_to_le64(sizeof(block->flush_id));
		if (write_metadata(lc, &entry, sizeof(entry), &block->flush_id,
				   sizeof(block->flush_id), sector)) {
			free_pending_block(lc, block);
			return -1;
		}
	} else if (write_metadata(lc, &entry, sizeof(entry), block->data,
				  metadatalen, sector)) {
		free_pending_block(lc, block);
		return -1;
	}

	sector += dev_to_bio_sectors(lc, 1);

	if (block->datalen && metadatalen == 0) {
		if (write_inline_data(lc, &entry, sizeof(entry), block->data,
				      block->datalen, sector)) {
			free_pending_block(lc, block);
			return -1;
		}
		/* we don't support both inline data & bio data */
		goto out;
	}

	if (!block->vec_cnt)
		goto out;

	atomic_inc(&lc->io_blocks);
	bio = bio_alloc(lc->logdev->bdev, bio_max_segs(block->vec_cnt),
			REQ_OP_WRITE, GFP_KERNEL);
	bio->bi_iter.bi_size = 0;
	bio->bi_iter.bi_sector = sector;
	bio->bi_end_io = log_end_io;
	bio->bi_private = lc;

	for (i = 0; i < block->vec_cnt; i++) {
		/*
		 * The page offset is always 0 because we allocate a new page
		 * for every bvec in the original bio for simplicity sake.
		 */
		ret = bio_add_page(bio, block->vecs[i].bv_page,
				   block->vecs[i].bv_len, 0);
		if (ret != block->vecs[i].bv_len) {
			atomic_inc(&lc->io_blocks);
			submit_bio(bio);
			bio = bio_alloc(lc->logdev->bdev,
					bio_max_segs(block->vec_cnt - i),
					REQ_OP_WRITE, GFP_KERNEL);
			bio->bi_iter.bi_size = 0;
			bio->bi_iter.bi_sector = sector;
			bio->bi_end_io = log_end_io;
			bio->bi_private = lc;

			ret = bio_add_page(bio, block->vecs[i].bv_page,
					   block->vecs[i].bv_len, 0);
			if (ret != block->vecs[i].bv_len) {
				DMERR("Couldn't add page on new bio?");
				bio_put(bio);
				goto error;
			}
		}
		sector += block->vecs[i].bv_len >> SECTOR_SHIFT;
	}
	submit_bio(bio);
out:
	kfree(block->data);
	kfree(block);
	put_pending_block(lc);
	return 0;
error:
	free_pending_block(lc, block);
	put_io_block(lc);
	return -1;
}

static int log_super(struct log_writes_c *lc)
{
	struct log_write_super super;

	super.magic = cpu_to_le64(WRITE_LOG_MAGIC);
	super.version = cpu_to_le64(WRITE_LOG_VERSION);
	super.nr_entries = cpu_to_le64(lc->logged_entries);
	super.sectorsize = cpu_to_le32(lc->sectorsize);

	if (write_metadata(lc, &super, sizeof(super), NULL, 0,
			   WRITE_LOG_SUPER_SECTOR)) {
		DMERR("Couldn't write super");
		return -1;
	}

	/*
	 * Super sector should be written in-order, otherwise the
	 * nr_entries could be rewritten incorrectly by an old bio.
	 */
	wait_for_completion_io(&lc->super_done);

	return 0;
}

static inline sector_t logdev_last_sector(struct log_writes_c *lc)
{
	return bdev_nr_sectors(lc->logdev->bdev);
}

static int log_writes_kthread(void *arg)
{
	struct log_writes_c *lc = arg;
	sector_t sector = 0;

	set_freezable();
	while (!kthread_should_stop()) {
		bool super = false;
		bool logging_enabled;
		struct pending_block *block = NULL;
		int ret;

		spin_lock_irq(&lc->blocks_lock);
		if (!list_empty(&lc->logging_blocks)) {
			block = list_first_entry(&lc->logging_blocks,
						 struct pending_block, list);
			list_del_init(&block->list);
			if (!lc->logging_enabled)
				goto next;

			sector = lc->next_sector;
			if (!(block->flags & LOG_DISCARD_FLAG))
				lc->next_sector += dev_to_bio_sectors(lc, block->nr_sectors);
			lc->next_sector += dev_to_bio_sectors(lc, 1);

			/*
			 * Apparently the size of the device may not be known
			 * right away, so handle this properly.
			 */
			if (!lc->end_sector)
				lc->end_sector = logdev_last_sector(lc);
			if (lc->end_sector &&
			    lc->next_sector >= lc->end_sector) {
				DMERR("Ran out of space on the logdev");
				lc->logging_enabled = false;
				goto next;
			}
			lc->logged_entries++;
			atomic_inc(&lc->io_blocks);

			super = (block->flags & (LOG_FUA_FLAG | LOG_MARK_FLAG));
			if (super)
				atomic_inc(&lc->io_blocks);
		}
next:
		logging_enabled = lc->logging_enabled;
		spin_unlock_irq(&lc->blocks_lock);
		if (block) {
			if (logging_enabled) {
				ret = log_one_block(lc, block, sector);
				if (!ret && super)
					ret = log_super(lc);
				if (ret) {
					spin_lock_irq(&lc->blocks_lock);
					lc->logging_enabled = false;
					spin_unlock_irq(&lc->blocks_lock);
				}
			} else
				free_pending_block(lc, block);
			continue;
		}

		if (!try_to_freeze()) {
			set_current_state(TASK_INTERRUPTIBLE);
			if (!kthread_should_stop() &&
			    list_empty(&lc->logging_blocks))
				schedule();
			__set_current_state(TASK_RUNNING);
		}
	}
	return 0;
}

/*
 * Construct a log-writes mapping:
 * log-writes <dev_path> <log_dev_path>
 */
static int log_writes_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
	struct log_writes_c *lc;
	struct dm_arg_set as;
	const char *devname, *logdevname;
	int ret;

	as.argc = argc;
	as.argv = argv;

	if (argc < 2) {
		ti->error = "Invalid argument count";
		return -EINVAL;
	}

	lc = kzalloc(sizeof(*lc), GFP_KERNEL);
	if (!lc) {
		ti->error = "Cannot allocate context";
		return -ENOMEM;
	}
	spin_lock_init(&lc->blocks_lock);
	INIT_LIST_HEAD(&lc->logging_blocks);
	init_waitqueue_head(&lc->wait);
	init_completion(&lc->super_done);
	atomic_set(&lc->io_blocks, 0);
	atomic_set(&lc->pending_blocks, 0);

	devname = dm_shift_arg(&as);
	ret = dm_get_device(ti, devname, dm_table_get_mode(ti->table), &lc->dev);
	if (ret) {
		ti->error = "Device lookup failed";
		goto bad;
	}

	logdevname = dm_shift_arg(&as);
	ret = dm_get_device(ti, logdevname, dm_table_get_mode(ti->table),
			    &lc->logdev);
	if (ret) {
		ti->error = "Log device lookup failed";
		dm_put_device(ti, lc->dev);
		goto bad;
	}

	lc->sectorsize = bdev_logical_block_size(lc->dev->bdev);
	lc->sectorshift = ilog2(lc->sectorsize);
	lc->log_kthread = kthread_run(log_writes_kthread, lc, "log-write-ord");
	if (IS_ERR(lc->log_kthread)) {
		ret = PTR_ERR(lc->log_kthread);
		ti->error = "Couldn't alloc kthread";
		dm_put_device(ti, lc->dev);
		dm_put_device(ti, lc->logdev);
		goto bad;
	}

	/*
	 * next_sector is in 512b sectors to correspond to what bi_sector expects.
	 * The super starts at sector 0, and the next_sector is the next logical
	 * one based on the sectorsize of the device.
	 */
	lc->next_sector = lc->sectorsize >> SECTOR_SHIFT;
	lc->logging_enabled = true;
	lc->end_sector = logdev_last_sector(lc);

	ti->num_flush_bios = 1;
	ti->flush_supported = true;
	ti->num_discard_bios = 1;	/* passed down only if dev takes them */
	ti->per_io_data_size = sizeof(struct per_bio_data);
	ti->private = lc;
	return 0;

bad:
	kfree(lc);
	return ret;
}

/* queue a block for the log thread, waking it if the queue was empty (the
 * thread drains the queue before it sleeps, rechecking it then) */
static void log_queue_block(struct log_writes_c *lc, struct pending_block *block)
{
	unsigned long flags;
	bool was_empty;

	spin_lock_irqsave(&lc->blocks_lock, flags);
	was_empty = list_empty(&lc->logging_blocks);
	list_add_tail(&block->list, &lc->logging_blocks);
	spin_unlock_irqrestore(&lc->blocks_lock, flags);
	if (was_empty)
		wake_up_process(lc->log_kthread);
}

static int log_mark(struct log_writes_c *lc, char *data)
{
	struct pending_block *block;
	size_t maxsize = lc->sectorsize - sizeof(struct log_write_entry);

	block = kzalloc(sizeof(*block), GFP_KERNEL);
	if (!block) {
		DMERR("Error allocating pending block");
		return -ENOMEM;
	}

	block->data = kstrndup(data, maxsize - 1, GFP_KERNEL);
	if (!block->data) {
		DMERR("Error copying mark data");
		kfree(block);
		return -ENOMEM;
	}
	atomic_inc(&lc->pending_blocks);
	block->datalen = strlen(block->data);
	block->flags |= LOG_MARK_FLAG;
	log_queue_block(lc, block);
	return 0;
}

static void log_writes_dtr(struct dm_target *ti)
{
	struct log_writes_c *lc = ti->private;

	/*
	 * This is just nice to have since it'll update the super to include the
	 * last blocks, if it fails we don't really care.
	 */
	log_mark(lc, "dm-log-writes-end");
	wake_up_process(lc->log_kthread);
	wait_event(lc->wait, !atomic_read(&lc->io_blocks) &&
		   !atomic_read(&lc->pending_blocks));
	kthread_stop(lc->log_kthread);

	WARN_ON(!list_empty(&lc->logging_blocks));
	dm_put_device(ti, lc->dev);
	dm_put_device(ti, lc->logdev);
	kfree(lc);
}

/*
 * A flush is being mapped: log its FLUSH_START entry now, after every write
 * that has completed (and so been logged) -- the writes this flush makes
 * durable -- and give the flush the same id for its FLUSH entry.
 */
static int log_flush_start(struct log_writes_c *lc, struct pending_block *flush)
{
	struct pending_block *start;
	unsigned long flags;
	bool was_empty;

	start = kzalloc(sizeof(*start), GFP_NOIO);
	if (!start)
		return -ENOMEM;
	INIT_LIST_HEAD(&start->list);
	start->flags = LOG_FLUSH_START_FLAG;
	atomic_inc(&lc->pending_blocks);
	spin_lock_irqsave(&lc->blocks_lock, flags);
	start->flush_id = flush->flush_id = cpu_to_le64(++lc->flush_seq);
	was_empty = list_empty(&lc->logging_blocks);
	list_add_tail(&start->list, &lc->logging_blocks);
	spin_unlock_irqrestore(&lc->blocks_lock, flags);
	if (was_empty)
		wake_up_process(lc->log_kthread);
	return 0;
}

static void normal_map_bio(struct dm_target *ti, struct bio *bio)
{
	struct log_writes_c *lc = ti->private;

	bio_set_dev(bio, lc->dev->bdev);
}

static int log_writes_map(struct dm_target *ti, struct bio *bio)
{
	struct log_writes_c *lc = ti->private;
	struct per_bio_data *pb = dm_per_bio_data(bio, sizeof(struct per_bio_data));
	struct pending_block *block;
	struct bvec_iter iter;
	struct bio_vec bv;
	size_t alloc_size;
	int i = 0;
	bool flush_bio = (bio->bi_opf & REQ_PREFLUSH);
	bool fua_bio = (bio->bi_opf & REQ_FUA);
	bool discard_bio = (bio_op(bio) == REQ_OP_DISCARD);
	bool meta_bio = (bio->bi_opf & REQ_META);

	pb->block = NULL;

	/* Don't bother doing anything if logging has been disabled */
	if (!lc->logging_enabled)
		goto map_bio;

	/*
	 * Map reads as normal.
	 */
	if (bio_data_dir(bio) == READ)
		goto map_bio;

	/* No sectors and not a flush?  Don't care */
	if (!bio_sectors(bio) && !flush_bio)
		goto map_bio;

	/*
	 * Discards will have bi_size set but there's no actual data, so just
	 * allocate the size of the pending block.
	 */
	if (discard_bio)
		alloc_size = sizeof(struct pending_block);
	else
		alloc_size = struct_size(block, vecs, bio_segments(bio));

	block = kzalloc(alloc_size, GFP_NOIO);
	if (!block) {
		DMERR("Error allocating pending block");
		spin_lock_irq(&lc->blocks_lock);
		lc->logging_enabled = false;
		spin_unlock_irq(&lc->blocks_lock);
		return DM_MAPIO_KILL;
	}
	INIT_LIST_HEAD(&block->list);
	pb->block = block;
	atomic_inc(&lc->pending_blocks);

	if (flush_bio)
		block->flags |= LOG_FLUSH_FLAG;
	if (fua_bio)
		block->flags |= LOG_FUA_FLAG;
	if (discard_bio)
		block->flags |= LOG_DISCARD_FLAG;
	if (meta_bio)
		block->flags |= LOG_METADATA_FLAG;

	block->sector = bio_to_dev_sectors(lc, bio->bi_iter.bi_sector);
	block->nr_sectors = bio_to_dev_sectors(lc, bio_sectors(bio));

	/* We don't need the data, just submit */
	if (discard_bio) {
		WARN_ON(flush_bio || fua_bio);
		goto map_bio;
	}

	/*
	 * The flush's FLUSH_START goes in the log now, its FLUSH at completion.
	 * Without it the log cannot say what this flush covered: stop logging
	 * (status shows logging_disabled, the harness fails the run) but pass
	 * the flush on -- a test-tool allocation is no member I/O error.
	 */
	if (flush_bio && log_flush_start(lc, block)) {
		DMERR("Error allocating flush start");
		free_pending_block(lc, block);
		pb->block = NULL;
		spin_lock_irq(&lc->blocks_lock);
		lc->logging_enabled = false;
		spin_unlock_irq(&lc->blocks_lock);
		goto map_bio;
	}
	if (flush_bio && !bio_sectors(bio))
		goto map_bio;

	/*
	 * We will write this bio somewhere else way later so we need to copy
	 * the actual contents into new pages so we know the data will always be
	 * there.
	 *
	 * We do this because this could be a bio from O_DIRECT in which case we
	 * can't just hold onto the page until some later point, we have to
	 * manually copy the contents.
	 */
	bio_for_each_segment(bv, bio, iter) {
		struct page *page;
		void *dst;

		page = alloc_page(GFP_NOIO);
		if (!page) {
			DMERR("Error allocing page");
			free_pending_block(lc, block);
			pb->block = NULL;
			spin_lock_irq(&lc->blocks_lock);
			lc->logging_enabled = false;
			spin_unlock_irq(&lc->blocks_lock);
			return DM_MAPIO_KILL;
		}

		dst = kmap_local_page(page);
		memcpy_from_bvec(dst, &bv);
		kunmap_local(dst);
		block->vecs[i].bv_page = page;
		block->vecs[i].bv_len = bv.bv_len;
		block->vec_cnt++;
		i++;
	}
map_bio:
	normal_map_bio(ti, bio);
	return DM_MAPIO_REMAPPED;
}

static int normal_end_io(struct dm_target *ti, struct bio *bio,
		blk_status_t *error)
{
	struct log_writes_c *lc = ti->private;
	struct per_bio_data *pb = dm_per_bio_data(bio, sizeof(struct per_bio_data));

	if (bio_data_dir(bio) == WRITE && pb->block) {
		struct pending_block *block = pb->block;

		pb->block = NULL;
		/* dm maps the bio again (noflush suspend): log that one instead */
		if (*error == BLK_STS_DM_REQUEUE) {
			free_pending_block(lc, block);
			return DM_ENDIO_DONE;
		}
		/* a write or flush that failed is no durability (replay skips it) */
		if (*error)
			block->flags |= LOG_ERROR_FLAG;
		/* every write, discard and flush is logged as it completes */
		log_queue_block(lc, block);
	}

	return DM_ENDIO_DONE;
}

/*
 * INFO format: <logged entries> <highest allocated sector>
 */
static void log_writes_status(struct dm_target *ti, status_type_t type,
			      unsigned int status_flags, char *result,
			      unsigned int maxlen)
{
	unsigned int sz = 0;
	struct log_writes_c *lc = ti->private;

	switch (type) {
	case STATUSTYPE_INFO:
		DMEMIT("%llu %llu", lc->logged_entries,
		       (unsigned long long)lc->next_sector - 1);
		if (!lc->logging_enabled)
			DMEMIT(" logging_disabled");
		break;

	case STATUSTYPE_TABLE:
		DMEMIT("%s %s", lc->dev->name, lc->logdev->name);
		break;

	default:
		*result = '\0';
		break;
	}
}

static int log_writes_iterate_devices(struct dm_target *ti,
				      iterate_devices_callout_fn fn,
				      void *data)
{
	struct log_writes_c *lc = ti->private;

	return fn(ti, lc->dev, 0, ti->len, data);
}

/*
 * Messages supported:
 *   mark <mark data> - specify the marked data.
 */
static int log_writes_message(struct dm_target *ti, unsigned int argc, char **argv,
			      char *result, unsigned int maxlen)
{
	int r = -EINVAL;
	struct log_writes_c *lc = ti->private;

	if (argc != 2) {
		DMWARN("Invalid log-writes message arguments, expect 2 arguments, got %d", argc);
		return r;
	}

	if (!strcasecmp(argv[0], "mark"))
		r = log_mark(lc, argv[1]);
	else
		DMWARN("Unrecognised log writes target message received: %s", argv[0]);

	return r;
}

static void log_writes_io_hints(struct dm_target *ti, struct queue_limits *limits)
{
	struct log_writes_c *lc = ti->private;

	limits->logical_block_size = bdev_logical_block_size(lc->dev->bdev);
	limits->physical_block_size = bdev_physical_block_size(lc->dev->bdev);
	limits->io_min = limits->physical_block_size;
}

static struct target_type log_writes_target = {
	.name   = "log-writes-ord",
	.version = {2, 0, 0},
	.module = THIS_MODULE,
	.ctr    = log_writes_ctr,
	.dtr    = log_writes_dtr,
	.map    = log_writes_map,
	.end_io = normal_end_io,
	.status = log_writes_status,
	.message = log_writes_message,
	.iterate_devices = log_writes_iterate_devices,
	.io_hints = log_writes_io_hints,
};

static int __init dm_log_writes_ord_init(void)
{
	return dm_register_target(&log_writes_target);
}

static void __exit dm_log_writes_ord_exit(void)
{
	dm_unregister_target(&log_writes_target);
}

module_init(dm_log_writes_ord_init);
module_exit(dm_log_writes_ord_exit);

MODULE_DESCRIPTION(DM_NAME " log writes target, completion-ordered (raidkm power-cut harness)");
MODULE_AUTHOR("Josef Bacik <jbacik@fb.com>");
MODULE_LICENSE("GPL");
