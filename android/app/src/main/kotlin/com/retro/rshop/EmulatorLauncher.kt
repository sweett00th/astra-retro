package com.retro.rshop

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Shares ROM files with emulators through content:// URIs. */
class RomFileProvider : FileProvider()

/**
 * Launches standalone emulators. Launch details (package, activity, action,
 * data and extras) come from the Dart emulator registry; this class only
 * turns them into an Intent and grants the emulator read access to the ROM.
 */
class EmulatorLauncher(private val context: Context) : MethodChannel.MethodCallHandler {

    private val authority = "${context.packageName}.roms"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installedPackages" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                result.success(installedPackages(packages))
            }
            "launch" -> try {
                launch(call)
                result.success(null)
            } catch (e: ActivityNotFoundException) {
                result.error("NOT_FOUND", "The emulator could not open this game (${e.message})", null)
            } catch (e: SecurityException) {
                result.error("DENIED", "Android blocked the launch (${e.message})", null)
            } catch (e: IllegalArgumentException) {
                result.error("BAD_REQUEST", e.message, null)
            }
            "openApp" -> {
                val pkg = call.argument<String>("package")
                val intent = pkg?.let { context.packageManager.getLaunchIntentForPackage(it) }
                if (intent == null) {
                    result.error("NOT_FOUND", "$pkg is not installed", null)
                } else {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun installedPackages(packages: List<String>): Map<String, Map<String, String?>> {
        val pm = context.packageManager
        val found = mutableMapOf<String, Map<String, String?>>()
        for (pkg in packages) {
            try {
                val info = if (Build.VERSION.SDK_INT >= 33) {
                    pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
                } else {
                    @Suppress("DEPRECATION")
                    pm.getPackageInfo(pkg, 0)
                }
                val label = info.applicationInfo?.loadLabel(pm)?.toString()
                found[pkg] = mapOf("label" to label, "versionName" to info.versionName)
            } catch (_: PackageManager.NameNotFoundException) {
            }
        }
        return found
    }

    /** Turns an absolute path into a content:// URI; other schemes pass through. */
    private fun toUri(value: String): Uri =
        if (value.startsWith("/")) FileProvider.getUriForFile(context, authority, File(value))
        else Uri.parse(value)

    private fun launch(call: MethodCall) {
        // No package: let the user pick any app that opens the file.
        val pkg = call.argument<String>("package")
        val intent = Intent(call.argument<String>("action") ?: Intent.ACTION_VIEW)
        val activity = call.argument<String>("activity")
        if (pkg != null && activity != null) {
            intent.component = ComponentName(pkg, if (activity.startsWith(".")) pkg + activity else activity)
        } else if (pkg != null) {
            intent.setPackage(pkg)
        }
        val grants = mutableListOf<Uri>()
        call.argument<String>("data")?.let { data ->
            val uri = toUri(data)
            val mime = call.argument<String>("mimeType")
            if (mime != null) intent.setDataAndType(uri, mime) else intent.data = uri
            grants += uri
        }
        val extras = call.argument<List<Map<String, Any?>>>("extras") ?: emptyList()
        for (extra in extras) {
            val key = extra["key"] as? String ?: continue
            val value = extra["value"]
            when (extra["type"]) {
                "bool" -> intent.putExtra(key, value as Boolean)
                "int" -> intent.putExtra(key, (value as Number).toInt())
                "long" -> intent.putExtra(key, (value as Number).toLong())
                "uri" -> {
                    val uri = toUri(value as String)
                    intent.putExtra(key, uri)
                    grants += uri
                }
                "uriString" -> {
                    val uri = toUri(value as String)
                    intent.putExtra(key, uri.toString())
                    grants += uri
                }
                else -> intent.putExtra(key, value?.toString())
            }
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (call.argument<Boolean>("clearTask") == true) {
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }
        if (grants.isNotEmpty()) {
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (pkg != null) {
                for (uri in grants) {
                    context.grantUriPermission(pkg, uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                }
            }
        }
        if (pkg == null) {
            context.startActivity(Intent.createChooser(intent, "Open with")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } else {
            context.startActivity(intent)
        }
    }
}
