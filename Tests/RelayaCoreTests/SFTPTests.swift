import Testing
@testable import RelayaCore

@Suite struct SFTPTests {
    @Test func parsesListing() {
        let out = """
        drwxr-xr-x    5 root     root         4096 Oct 29 12:00 .
        drwxr-xr-x   18 root     root         4096 Oct  1  2025 ..
        -rw-r--r--    1 root     root          220 Jan  6 09:13 .bashrc
        drwx------    2 root     root         4096 Oct 29 12:00 .ssh
        -rw-r--r--    1 root     root      1048576 Oct 28 23:59 my file.tar.gz
        lrwxrwxrwx    1 root     root           11 Oct 29 12:00 logs -> /var/log
        """
        let files = SFTPClient.parseListing(out)
        #expect(files.map(\.name) == [".ssh", ".bashrc", "logs", "my file.tar.gz"])
        #expect(files[0].isDirectory)
        #expect(files[2].isLink)
        #expect(files[3].size == 1_048_576)
        #expect(files[3].modified == "Oct 28 23:59")
    }

    @Test func quotesAndPaths() {
        #expect(SFTPClient.quote(#"a "b"\c"#) == #""a \"b\"\\c""#)
        #expect(SFTPClient.join("/root", "x") == "/root/x")
        #expect(SFTPClient.join("/", "etc") == "/etc")
        #expect(SFTPClient.parent(of: "/var/log/") == "/var")
        #expect(SFTPClient.parent(of: "/etc") == "/")
        #expect(SFTPClient.parent(of: "/") == "/")
    }
}
