import Foundation

extension SSHFileServer: FileServerEngine {}
extension FTPServer: FileServerEngine {}

extension FileServerEngines {
    /// Installed once at launch (AppModel init): the SSH (SFTP + SCP) and
    /// FTP engines the File Server popover switches on.
    static func install() {
        ssh = { access, keys in SSHFileServer(access: access, hostKeyDirectory: keys) }
        ftp = { access in FTPServer(access: access) }
    }
}
