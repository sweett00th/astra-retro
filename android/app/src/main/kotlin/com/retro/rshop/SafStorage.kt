package com.retro.rshop

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Saves system files (BIOS, firmware, keys) into folders the user picked with
 * Android's folder picker. Access comes only from the persisted grant for that
 * folder (Storage Access Framework); nothing here relies on broad storage
 * permission or on reaching another app's Android/data folder.
 */
class SafStorage(private val activity: Activity) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val PICK_TREE_REQUEST = 0x5AF1
        private const val TAG = "SafStorage"
        private const val PARTIAL_SUFFIX = ".rshop-partial"
        private const val GRANT_FLAGS =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    }

    // Copies and checksums can run for minutes; folder queries must not wait
    // behind them.
    private val transferPool = Executors.newSingleThreadExecutor()
    private val queryPool = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val resolver get() = activity.contentResolver
    private var pendingPick: MethodChannel.Result? = null
    private var progressSink: EventChannel.EventSink? = null

    // Copies in flight by transfer id; set the flag to stop one.
    private val copies = ConcurrentHashMap<String, AtomicBoolean>()

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickTree" -> pickTree(call.argument<String>("initialUri"), result)
            "canWrite" -> background(result) { canWrite(treeArg(call)) }
            "release" -> background(result) { release(treeArg(call)); null }
            "findDocument" -> background(result) {
                val tree = treeArg(call)
                folderId(tree, pathArg(call), create = false)
                    ?.let { findChild(tree, it, nameArg(call)) }
                    ?.toMap()
            }
            "copyFile" -> {
                // Registered here, on the main thread, so a cancel that
                // follows this call always finds it.
                val transferId = call.argument<String>("transferId")!!
                val stop = AtomicBoolean(false)
                copies[transferId] = stop
                background(result, transferPool) {
                    try {
                        copyFile(
                            File(call.argument<String>("sourcePath")!!),
                            treeArg(call),
                            pathArg(call),
                            nameArg(call),
                            transferId,
                            call.argument<Boolean>("replace") ?: false,
                            stop,
                        ).toMap()
                    } finally {
                        copies.remove(transferId, stop)
                    }
                }
            }
            "cancelCopy" -> {
                copies[call.argument<String>("transferId")!!]?.set(true)
                result.success(null)
            }
            "sha256" -> background(result, transferPool) { sha256(uriArg(call)) }
            "deleteDocument" -> background(result) { deleteFile(uriArg(call)); null }
            else -> result.notImplemented()
        }
    }

    fun shutdown() {
        transferPool.shutdown()
        queryPool.shutdown()
    }

    private fun treeArg(call: MethodCall): Uri = Uri.parse(call.argument<String>("treeUri")!!)

    private fun uriArg(call: MethodCall): Uri = Uri.parse(call.argument<String>("uri")!!)

    private fun nameArg(call: MethodCall): String = requireName(call.argument<String>("name")!!)

    /** Folders below the granted folder, outermost first. */
    private fun pathArg(call: MethodCall): List<String> =
        (call.argument<List<String>>("path") ?: emptyList()).map { requireName(it) }

    /** One path segment: never empty, a separator or a way up the tree. */
    private fun requireName(name: String): String {
        if (name.isEmpty() || name == "." || name == ".." ||
            name.contains('/') || name.contains('\\') || name.contains('\u0000')
        ) {
            throw IOException("Invalid file name.")
        }
        return name
    }

    private fun background(
        result: MethodChannel.Result,
        pool: ExecutorService = queryPool,
        work: () -> Any?,
    ) {
        pool.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: SecurityException) {
                main.post { result.error("NO_ACCESS", "Access to this folder was withdrawn.", null) }
            } catch (e: Exception) {
                Log.w(TAG, "SAF operation failed", e)
                main.post { result.error("SAF_ERROR", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    // ------------------------------------------------------------- picking

    private fun pickTree(initialUri: String?, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("BUSY", "A folder picker is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(GRANT_FLAGS or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            if (initialUri != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initialUri))
            }
        }
        pendingPick = result
        try {
            activity.startActivityForResult(intent, PICK_TREE_REQUEST)
        } catch (e: Exception) {
            pendingPick = null
            result.error("NO_PICKER", "This device has no folder picker.", null)
        }
    }

    /** Returns true when the activity result belonged to the folder picker. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_TREE_REQUEST) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return true
        }
        try {
            // Keeps the grant across restarts of the app and the device.
            resolver.takePersistableUriPermission(tree, GRANT_FLAGS)
            result.success(mapOf("uri" to tree.toString(), "name" to displayName(tree)))
        } catch (e: Exception) {
            result.error("NO_ACCESS", "Android did not grant access to that folder.", null)
        }
        return true
    }

    private fun rootId(tree: Uri): String = DocumentsContract.getTreeDocumentId(tree)

    private fun documentUri(tree: Uri, id: String): Uri =
        DocumentsContract.buildDocumentUriUsingTree(tree, id)

    /** "Internal storage/Emulation/bios" style label for a granted folder. */
    private fun displayName(tree: Uri): String {
        val id = rootId(tree)
        val volume = id.substringBefore(':', "")
        val path = id.substringAfter(':', id)
        val root = if (volume == "primary") "Internal storage" else volume
        return when {
            path.isEmpty() -> root
            root.isEmpty() -> path
            else -> "$root/$path"
        }
    }

    private fun canWrite(tree: Uri): Boolean {
        val granted = resolver.persistedUriPermissions.any {
            it.uri == tree && it.isWritePermission && it.isReadPermission
        }
        if (!granted) return false
        // The grant outlives the folder; make sure the folder is still there.
        return try {
            mimeOf(documentUri(tree, rootId(tree))) == Document.MIME_TYPE_DIR
        } catch (e: Exception) {
            false
        }
    }

    private fun release(tree: Uri) {
        try {
            resolver.releasePersistableUriPermission(tree, GRANT_FLAGS)
        } catch (e: SecurityException) {
            // Already gone.
        }
    }

    // ----------------------------------------------------------- documents

    private data class Doc(val uri: Uri, val id: String, val size: Long, val isFolder: Boolean) {
        fun toMap() = mapOf("uri" to uri.toString(), "size" to size, "folder" to isFolder)
    }

    private fun findChild(tree: Uri, parentId: String, name: String): Doc? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_SIZE,
            Document.COLUMN_MIME_TYPE,
        )
        resolver.query(children, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) == name) {
                    val id = cursor.getString(0)
                    return Doc(
                        documentUri(tree, id),
                        id,
                        if (cursor.isNull(2)) 0 else cursor.getLong(2),
                        cursor.getString(3) == Document.MIME_TYPE_DIR,
                    )
                }
            }
        }
        return null
    }

    /**
     * Id of the folder at [path] below the granted folder. Missing folders
     * are created when [create] is set; otherwise the answer is null.
     */
    private fun folderId(tree: Uri, path: List<String>, create: Boolean): String? {
        var parent = rootId(tree)
        for (segment in path) {
            val child = findChild(tree, parent, segment)
            parent = when {
                child == null && !create -> return null
                child == null -> DocumentsContract.getDocumentId(
                    DocumentsContract.createDocument(
                        resolver, documentUri(tree, parent), Document.MIME_TYPE_DIR, segment,
                    ) ?: throw IOException("Could not create the folder $segment."),
                )
                child.isFolder -> child.id
                else -> throw IOException("$segment is a file where a folder is needed.")
            }
        }
        return parent
    }

    private fun <T> column(document: Uri, name: String, read: (android.database.Cursor) -> T): T? =
        resolver.query(document, arrayOf(name), null, null, null)
            ?.use { if (it.moveToFirst() && !it.isNull(0)) read(it) else null }

    private fun sizeOf(document: Uri): Long = column(document, Document.COLUMN_SIZE) { it.getLong(0) } ?: 0

    private fun nameOf(document: Uri): String? =
        column(document, Document.COLUMN_DISPLAY_NAME) { it.getString(0) }

    private fun mimeOf(document: Uri): String? =
        column(document, Document.COLUMN_MIME_TYPE) { it.getString(0) }

    /** Deletes one file. Never a folder: that would take its contents along. */
    private fun deleteFile(document: Uri) {
        if (mimeOf(document) == Document.MIME_TYPE_DIR) {
            throw IOException("Refusing to delete a folder.")
        }
        DocumentsContract.deleteDocument(resolver, document)
    }

    private fun create(tree: Uri, parentId: String, name: String): Uri =
        // application/octet-stream keeps the name exactly as given (prod.keys,
        // PS3UPDAT.PUP); other types make providers append an extension.
        DocumentsContract.createDocument(
            resolver, documentUri(tree, parentId), "application/octet-stream", name,
        ) ?: throw IOException("Could not create $name in the chosen folder.")

    private fun write(source: File, target: Uri, transferId: String, stop: AtomicBoolean) {
        val total = source.length()
        var copied = 0L
        var lastReport = 0L
        val descriptor = resolver.openFileDescriptor(target, "wt")
            ?: throw IOException("Could not open the destination for writing.")
        // The stream owns the descriptor and closes it exactly once.
        ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { output ->
            FileInputStream(source).use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) {
                    if (stop.get()) throw IOException("The copy was cancelled.")
                    val read = input.read(buffer)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                    copied += read
                    val now = System.currentTimeMillis()
                    if (now - lastReport >= 250) {
                        lastReport = now
                        report(transferId, copied, total)
                    }
                }
            }
            output.flush()
            try {
                output.fd.sync()
            } catch (e: IOException) {
                // Some providers do not support sync; the size check still applies.
            }
        }
        report(transferId, copied, total)
    }

    private fun report(transferId: String, copied: Long, total: Long) {
        main.post {
            progressSink?.success(mapOf("transferId" to transferId, "copied" to copied, "total" to total))
        }
    }

    /**
     * Writes [source] as exactly [name] into the folder at [path] below the
     * granted folder, creating that path if needed. The bytes go to a
     * temporary document first and take the final name only once complete,
     * so [name] never refers to a half-written file.
     */
    private fun copyFile(
        source: File,
        tree: Uri,
        path: List<String>,
        name: String,
        transferId: String,
        replace: Boolean,
        stop: AtomicBoolean,
    ): Doc {
        val parent = folderId(tree, path, create = true)!!
        val existing = findChild(tree, parent, name)
        if (existing != null && existing.isFolder) throw IOException("A folder named $name is in the way.")
        if (existing != null && !replace) throw IOException("$name already exists in the chosen folder.")
        val partialName = name + PARTIAL_SUFFIX
        findChild(tree, parent, partialName)?.let { deleteFile(it.uri) }

        val partial = create(tree, parent, partialName)
        var leftover: Uri? = partial
        try {
            write(source, partial, transferId, stop)
            if (sizeOf(partial) != source.length()) throw IOException("The file was not written completely.")
            if (existing != null) deleteFile(existing.uri)
            val renamed: Uri? = try {
                DocumentsContract.renameDocument(resolver, partial, name)
            } catch (e: Exception) {
                null
            }
            if (renamed != null) leftover = renamed
            if (renamed != null && nameOf(renamed) == name) {
                leftover = null
                return Doc(renamed, DocumentsContract.getDocumentId(renamed), sizeOf(renamed), false)
            }
            // This provider cannot rename: drop the temporary document and
            // write under the final name directly.
            leftover?.let { deleteFile(it) }
            leftover = null
            val direct = create(tree, parent, name)
            leftover = direct
            write(source, direct, transferId, stop)
            if (nameOf(direct) != name || sizeOf(direct) != source.length()) {
                throw IOException("The folder did not keep the file as $name.")
            }
            leftover = null
            return Doc(direct, DocumentsContract.getDocumentId(direct), sizeOf(direct), false)
        } finally {
            leftover?.let {
                try { deleteFile(it) } catch (ignored: Exception) {}
            }
        }
    }

    private fun sha256(document: Uri): String {
        val digest = MessageDigest.getInstance("SHA-256")
        resolver.openInputStream(document)?.use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        } ?: throw IOException("Could not read the saved file.")
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
