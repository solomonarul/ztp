# ZTP

ZTP is a simple FTP server and client implementation in Zig.

It can be used as a standalone executable or be compiled as a library if needed in one's own application.

The server is intentionally designed with a single client logged in and working at all times, thus prone to blocking. (TODO: maybe multithread?)

## What works:

- Server-side supported commands:
    - [x] Logging in.
    - [ ] Listing files.
    - [ ] Changing working directory.
    - [ ] Uploading a file.
    - [ ] Downloading a file.

- Client-side supported commands:
    - [ ] Logging in.
    - [ ] Listing files.
    - [ ] Changing working directory.
    - [ ] Uploading a file.
    - [ ] Downloading a file.