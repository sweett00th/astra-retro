package com.retro.rshop

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Shares a downloaded update of this app with Android's installer, nothing else. */
class UpdateFileProvider : FileProvider()

/**
 * Hands an update the app downloaded (see app_update_service.dart) to Android's
 * installer. Android asks the user to confirm, and only replaces the app when
 * the file is signed with the same key as the installed build.
 */
class AppUpdater(private val activity: Activity) : MethodChannel.MethodCallHandler {

    private val authority = "${activity.packageName}.update"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canInstall" -> result.success(canInstall())
            "openInstallPermission" -> try {
                openInstallPermission()
                result.success(null)
            } catch (e: ActivityNotFoundException) {
                result.error("NOT_FOUND", "Android has no page for this permission on this device", null)
            }
            "install" -> try {
                install(call.argument<String>("path"))
                result.success(null)
            } catch (e: IllegalArgumentException) {
                result.error("BAD_FILE", e.message, null)
            } catch (e: ActivityNotFoundException) {
                result.error("NOT_FOUND", "Android has no installer that opens this file", null)
            } catch (e: SecurityException) {
                result.error("DENIED", "Android blocked the install (${e.message})", null)
            }
            else -> result.notImplemented()
        }
    }

    /** "Install unknown apps" for this app; the permission exists since Android 8. */
    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            activity.packageManager.canRequestPackageInstalls()

    private fun openInstallPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        activity.startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}")
            )
        )
    }

    private fun install(path: String?) {
        // Only an update this app downloaded itself: cache/app_update/<name>.apk.
        val updates = File(activity.cacheDir, "app_update").canonicalFile
        val apk = File(requireNotNull(path) { "No file to install" }).canonicalFile
        require(apk.parentFile == updates && apk.isFile && apk.name.endsWith(".apk")) {
            "Not a downloaded update: ${apk.name}"
        }
        val uri = FileProvider.getUriForFile(activity, authority, apk)
        activity.startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        )
    }
}
