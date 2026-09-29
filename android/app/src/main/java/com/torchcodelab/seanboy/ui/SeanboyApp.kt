package com.torchcodelab.seanboy.ui

import androidx.compose.foundation.clickable
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
import androidx.compose.material3.ExperimentalMaterial3Api
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
    val query by vm.query.collectAsState()
    val sync by vm.sync.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Seanboy") },
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
                placeholder = { Text("Search notes…") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            )
            SyncStatusLine(sync)
            HorizontalDivider()
            if (results.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        if (query.isBlank()) "No notes yet — tap ＋ to start" else "No matches",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(results, key = { it.id }) { note ->
                        NoteRow(note) { vm.select(note.id) }
                        HorizontalDivider()
                    }
                }
            }
        }
    }
}

@Composable
private fun NoteRow(note: Note, onClick: () -> Unit) {
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
        if (note.folder.isNotEmpty()) {
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
