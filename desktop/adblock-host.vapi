/* SPDX-License-Identifier: LGPL-2.1-or-later */
[CCode (cheader_filename = "adblock-host.h")]
namespace Xanh {
    [CCode (cname = "XanhAdblockHostError", cprefix = "XANH_ADBLOCK_HOST_ERROR_")]
    public errordomain AdblockHostError {
        UNAVAILABLE,
        INVALID_INPUT,
        BUSY,
        CORE,
        INVALID_OUTPUT;
        [CCode (cname = "xanh_adblock_host_error_quark")]
        public static GLib.Quark quark ();
    }

    [CCode (cname = "xanh_adblock_host_is_available")]
    public bool adblock_host_is_available ();

    [CCode (
        cname = "xanh_adblock_host_compile_async",
        finish_name = "xanh_adblock_host_compile_finish")]
    public async GLib.Bytes adblock_host_compile_async (
        string filter_list,
        GLib.Cancellable? cancellable = null) throws GLib.Error;
}
