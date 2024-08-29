const c = @cImport({
    @cInclude("libgit2.h");
});

pub fn init() void {
    c.git_libgit2_init();
}
