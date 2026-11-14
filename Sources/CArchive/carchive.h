// 系统自带 libarchive（/usr/lib/libarchive.2.dylib）的公开 API 子集。
// macOS SDK 只带了链接桩（libarchive.tbd），没带头文件，这里按 libarchive 3.x 的 archive.h /
// archive_entry.h 声明用到的部分（libarchive 为 BSD 许可，C ABI 多年稳定）。
#ifndef HARBOR_CARCHIVE_H
#define HARBOR_CARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <time.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF       1
#define ARCHIVE_OK        0
#define ARCHIVE_RETRY   (-10)
#define ARCHIVE_WARN    (-20)
#define ARCHIVE_FAILED  (-25)
#define ARCHIVE_FATAL   (-30)

#define ARCHIVE_FORMAT_BASE_MASK 0xff0000
#define ARCHIVE_FORMAT_ZIP 0x50000
#define ARCHIVE_FORMAT_RAW 0x90000

#define ARCHIVE_EXTRACT_PERM                   (0x0002)
#define ARCHIVE_EXTRACT_TIME                   (0x0004)
#define ARCHIVE_EXTRACT_NO_OVERWRITE           (0x0008)
#define ARCHIVE_EXTRACT_XATTR                  (0x0080)
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS        (0x0100)
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT        (0x0200)
#define ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS (0x10000)

#define AE_IFMT   ((mode_t)0170000)
#define AE_IFREG  ((mode_t)0100000)
#define AE_IFLNK  ((mode_t)0120000)
#define AE_IFDIR  ((mode_t)0040000)

int archive_version_number(void);
const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);
int archive_format(struct archive *);
const char *archive_format_name(struct archive *);
int64_t archive_filter_bytes(struct archive *, int);
int archive_filter_count(struct archive *);

// 读压缩包
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_cpio(struct archive *);
int archive_read_support_format_iso9660(struct archive *);
int archive_read_support_format_xar(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_block(struct archive *, const void **, size_t *, int64_t *);
int archive_read_data_skip(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);

// 写磁盘（解压）
struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int);
int archive_write_disk_set_standard_lookup(struct archive *);

// 写压缩包
struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_set_format_7zip(struct archive *);
int archive_write_add_filter_gzip(struct archive *);
int archive_write_add_filter_xz(struct archive *);
int archive_write_set_options(struct archive *, const char *);
int archive_write_open_filename(struct archive *, const char *);

// 两种写入共用
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
ssize_t archive_write_data_block(struct archive *, const void *, size_t, int64_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

// 条目
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
struct archive_entry *archive_entry_clear(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
void archive_entry_copy_pathname(struct archive_entry *, const char *);
int archive_entry_update_pathname_utf8(struct archive_entry *, const char *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_copy_stat(struct archive_entry *, const struct stat *);
void archive_entry_copy_symlink(struct archive_entry *, const char *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
void archive_entry_copy_hardlink(struct archive_entry *, const char *);
int archive_entry_is_encrypted(struct archive_entry *);

#endif
