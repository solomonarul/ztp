# This is used for development purposes only.
.PHONY: all

c:
	@rm -rf .zig-cache
	@rm -rf zig-out

r:
	@zig build -Doptimize=Debug -freference-trace run-server