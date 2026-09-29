package com.torchcodelab.seanboy.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.torchcodelab.seanboy.core.FolderListing
import com.torchcodelab.seanboy.core.Note
import com.torchcodelab.seanboy.core.WikiLinkParser

@Composable
fun SeanboyApp(vm: NotesViewModel) {
    val selected by vm.selectedNote.collectAsState()
    var showSettings by rememberSaveable { mutableStateOf(false) }

    when {
        showSettings -> SettingsScreen(vm, onBack = { showSettings = false })
        selected != null -> EditorScreen(vm, note = selected!!)
        else -> NotesListScreen(vm, onOpenSettings = { showSettings = true })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NotesListScreen(vm: NotesViewModel, onOpenSettings: () -> Unit) {
    val results by vm.results.collectAsState()
    val listing by vm.listing.collectAsState()
    val query by vm.query.collectAsState()
    val sync by vm.sync.collectAsState()
    val searching = query.isNotBlank()
    val inFolder = !searching && listing.folder.isNotEmpty()

    // Back: clear a search first, then climb out of folders, then leave.
    BackHandler(enabled = searching || inFolder) {
        if (searching) vm.setQuery("") else vm.goUp()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (inFolder) listing.folder.substringAfterLast('/') else "Seanboy") },
                navigationIcon = {
                    if (inFolder) {
                        IconButton(onClick = { vm.goUp() }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Up one folder")
                        }
                    }
                },
                actions = {
                    TextButton(onClick = vm::syncNow) { Text("Sync") }
                    TextButton(onClick = onOpenSettings) { Text("Settings") }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = vm::createNote) { Text("＋", style = MaterialTheme.typography.headlineSmall) }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            OutlinedTextField(
                value = query,
                onValueChange = vm::setQuery,
                placeholder = { Text("Search all notes…") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            )
            SyncStatusLine(sync)
            if (inFolder) Breadcrumbs(listing.folder, onOpen = vm::openFolder)
            HorizontalDivider()
            if (searching) {
                // Search is flat and global — the Tomboy soul — across every folder.
                if (results.isEmpty()) {
                    EmptyMessage("No matches")
                } else {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(results, key = { it.id }) { note ->
                            NoteRow(note, showFolder = true) { vm.select(note.id) }
                            HorizontalDivider()
                        }
                    }
                }
            } else if (listing.subfolders.isEmpty() && listing.notes.isEmpty()) {
                EmptyMessage("No notes yet — tap ＋ to start")
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(listing.subfolders, key = { "folder:" + it.path }) { folder ->
                        FolderRow(folder) { vm.openFolder(folder.path) }
                        HorizontalDivider()
                    }
                    items(listing.notes, key = { it.id }) { note ->
                        NoteRow(note, showFolder = false) { vm.select(note.id) }
                        HorizontalDivider()
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyMessage(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, style = MaterialTheme.typography.bodyMedium)
    }
}

/** "Seanboy › Journal › 2026" — every segment but the current one is tappable. */
@Composable
private fun Breadcrumbs(folder: String, onOpen: (String) -> Unit) {
    val crumbs = FolderListing.breadcrumbs(folder, rootName = "Seanboy")
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        crumbs.forEachIndexed { index, crumb ->
            val isCurrent = index == crumbs.lastIndex
            if (index > 0) {
                Text("›", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (isCurrent) {
                Text(
                    crumb.name,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 12.dp),
                )
            } else {
                TextButton(onClick = { onOpen(crumb.path) }) { Text(crumb.name) }
            }
        }
    }
}

@Composable
private fun FolderRow(folder: FolderListing.Subfolder, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(folder.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                 color = MaterialTheme.colorScheme.primary)
            Text(
                if (folder.noteCount == 1) "1 note" else "${folder.noteCount} notes",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = "Open folder",
             tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun NoteRow(note: Note, showFolder: Boolean, onClick: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text(note.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        val snippet = note.body.trim().replace("\n", " ")
        if (snippet.isNotEmpty()) {
            Text(
                snippet.take(100),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (showFolder && note.folder.isNotEmpty()) {
            Text(note.folder, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EditorScreen(vm: NotesViewModel, note: Note) {
    // Local edit state keyed to the note so switching notes resets the fields.
    var title by remember(note.id) { mutableStateOf(note.title) }
    var body by remember(note.id) { mutableStateOf(note.body) }
    val links = remember(body) { WikiLinkParser.linkedTitles(body) }
    val backlinks = remember(note.id, body) { vm.backlinks(note) }
    BackHandler { vm.select(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Edit") },
                navigationIcon = { TextButton(onClick = { vm.select(null) }) { Text("Back") } },
                actions = { TextButton(onClick = { vm.delete(note.id) }) { Text("Delete") } },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("Title") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { if (title.isNotBlank()) vm.rename(note.id, title) }),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = body,
                onValueChange = { body = it; vm.updateBody(note.id, it) },
                label = { Text("Markdown") },
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
            if (links.isNotEmpty()) {
                LinkRow("Links", links, onClick = vm::openWikiLink)
            }
            if (backlinks.isNotEmpty()) {
                LinkRow("Backlinks", backlinks.map { it.title }, onClick = vm::openWikiLink)
            }
        }
    }
}

@Composable
private fun LinkRow(label: String, titles: List<String>, onClick: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            titles.distinct().take(12).forEach { t ->
                TextButton(onClick = { onClick(t) }) { Text("[[${t}]]") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsScreen(vm: NotesViewModel, onBack: () -> Unit) {
    val existing = remember { vm.currentConfig() }
    var endpoint by rememberSaveable { mutableStateOf(existing?.endpoint ?: "") }
    var bucket by rememberSaveable { mutableStateOf(existing?.bucket ?: "") }
    var region by rememberSaveable { mutableStateOf(existing?.region ?: "auto") }
    var accessKey by rememberSaveable { mutableStateOf(existing?.accessKeyID ?: "") }
    var secret by rememberSaveable { mutableStateOf(existing?.secretAccessKey ?: "") }
    val sync by vm.sync.collectAsState()
    BackHandler(onBack = onBack)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sync settings") },
                navigationIcon = { TextButton(onClick = onBack) { Text("Back") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                "Point Seanboy at your own R2 (or any S3) bucket. Credentials are stored encrypted on this device only.",
                style = MaterialTheme.typography.bodySmall,
            )
            Field("Endpoint (https://<account>.r2.cloudflarestorage.com)", endpoint) { endpoint = it }
            Field("Bucket", bucket) { bucket = it }
            Field("Region", region) { region = it }
            Field("Access Key ID", accessKey) { accessKey = it }
            Field("Secret Access Key", secret) { secret = it }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = {
                    vm.saveCredentials(
                        com.torchcodelab.seanboy.core.S3Config(
                            endpoint = endpoint, bucket = bucket,
                            region = region.ifBlank { "auto" },
                            accessKeyID = accessKey, secretAccessKey = secret,
                        ),
                    )
                }) { Text("Save") }
                TextButton(onClick = vm::syncNow) { Text("Sync now") }
                TextButton(onClick = vm::clearCredentials) { Text("Clear") }
            }
            SyncStatusLine(sync)
        }
    }
}

@Composable
private fun Field(label: String, value: String, onValueChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun SyncStatusLine(status: SyncStatus) {
    val text = when (status) {
        SyncStatus.NotConfigured -> "Sync off — add R2 credentials in Settings"
        SyncStatus.Idle -> "Configured — tap Sync"
        SyncStatus.Syncing -> "Syncing…"
        is SyncStatus.Ok -> "Synced (${status.summary})"
        is SyncStatus.Failed -> "Sync failed: ${status.message}"
    }
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        color = if (status is SyncStatus.Failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
    )
}
