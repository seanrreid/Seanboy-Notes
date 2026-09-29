package com.torchcodelab.seanboy.ui

import androidx.activity.compose.BackHandler
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.imePadding
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Surface
import android.text.format.DateUtils
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import com.torchcodelab.seanboy.core.NotePreview
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import com.torchcodelab.seanboy.ui.editor.LivePreviewEditText
import com.torchcodelab.seanboy.ui.editor.LivePreviewEditor
import kotlinx.coroutines.launch
import java.util.UUID

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

    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()

    // Back: clear a search first, then climb out of folders, then leave.
    BackHandler(enabled = searching || inFolder) {
        if (searching) vm.setQuery("") else vm.goUp()
    }
    // Registered last so it wins: an open drawer closes before anything else.
    BackHandler(enabled = drawerState.isOpen) { scope.launch { drawerState.close() } }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            FolderDrawer(
                vm,
                current = if (searching) null else listing.folder,
                onPick = { path ->
                    vm.setQuery("")
                    vm.openFolder(path)
                    scope.launch { drawerState.close() }
                },
            )
        },
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(if (inFolder) listing.folder.substringAfterLast('/') else "Seanboy") },
                    navigationIcon = {
                        Row {
                            IconButton(onClick = { scope.launch { drawerState.open() } }) {
                                Icon(Icons.Filled.Menu, contentDescription = "Folders")
                            }
                            if (inFolder) {
                                IconButton(onClick = { vm.goUp() }) {
                                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Up one folder")
                                }
                            }
                        }
                    },
                    actions = {
                        SyncButton(sync, onClick = vm::syncNow)
                        IconButton(onClick = onOpenSettings) {
                            Icon(Icons.Filled.Settings, contentDescription = "Settings")
                        }
                    },
                )
            },
            floatingActionButton = {
                FloatingActionButton(onClick = vm::createNote) { Text("＋", style = MaterialTheme.typography.headlineSmall) }
            },
        ) { padding ->
            Column(Modifier.fillMaxSize().padding(padding)) {
                SearchField(query, onChange = vm::setQuery)
                // Routine states show on the sync button; only problems get a line.
                if (sync is SyncStatus.Failed || sync is SyncStatus.NotConfigured) SyncStatusLine(sync)
                if (inFolder) Breadcrumbs(listing.folder, onOpen = vm::openFolder)
                // Folders live only in the drawer. The main list is search results
                // (flat and global — the Tomboy soul), a folder's own notes, or,
                // at home, the most recently edited notes from anywhere.
                when {
                    searching -> NoteList(results, showFolder = true, empty = "No matches", onOpen = vm::select)
                    inFolder -> NoteList(listing.notes, showFolder = false, empty = "No notes directly in this folder", onOpen = vm::select)
                    else -> {
                        Text(
                            "Recent",
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                        NoteList(results.take(RECENT_COUNT), showFolder = true, empty = "No notes yet — tap ＋ to start", onOpen = vm::select)
                    }
                }
            }
        }
    }
}

/**
 * The side drawer: the whole folder tree, like the Mac sidebar. Folders with
 * subfolders expand and collapse; the path to the current folder starts open.
 * [current] is null while searching, since search spans every folder.
 */
@Composable
private fun FolderDrawer(vm: NotesViewModel, current: String?, onPick: (String) -> Unit) {
    val tree by vm.folderTree.collectAsState()
    var expanded by remember { mutableStateOf(setOf<String>()) }
    LaunchedEffect(current) {
        var folder = current.orEmpty()
        while (folder.isNotEmpty()) {
            folder = FolderListing.parent(folder)
            if (folder.isNotEmpty()) expanded = expanded + folder
        }
    }

    ModalDrawerSheet {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 12.dp)) {
            Text(
                "Folders",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 28.dp, vertical = 12.dp),
            )
            NavigationDrawerItem(
                label = { Text("Seanboy") },
                selected = current == "",
                onClick = { onPick("") },
                modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
            )
            tree.forEachIndexed { index, folder ->
                val visible = generateSequence(FolderListing.parent(folder.path)) { p ->
                    if (p.isEmpty()) null else FolderListing.parent(p)
                }.all { it.isEmpty() || it in expanded }
                if (!visible) return@forEachIndexed
                val hasChildren = tree.getOrNull(index + 1)?.path?.startsWith(folder.path + "/") == true
                val isOpen = folder.path in expanded
                NavigationDrawerItem(
                    label = { Text(folder.name, maxLines = 1) },
                    selected = current == folder.path,
                    onClick = { onPick(folder.path) },
                    badge = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(folder.noteCount.toString(), style = MaterialTheme.typography.labelMedium)
                            if (hasChildren) {
                                IconButton(onClick = {
                                    expanded = if (isOpen) expanded - folder.path else expanded + folder.path
                                }) {
                                    Icon(
                                        if (isOpen) Icons.Filled.KeyboardArrowDown
                                        else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                        contentDescription = if (isOpen) "Collapse ${folder.name}" else "Expand ${folder.name}",
                                    )
                                }
                            }
                        }
                    },
                    modifier = Modifier
                        .padding(NavigationDrawerItemDefaults.ItemPadding)
                        .padding(start = (16 * FolderListing.depth(folder.path)).dp),
                )
            }
        }
    }
}

/** How many notes the home screen shows. */
private const val RECENT_COUNT = 5

@Composable
private fun NoteList(notes: List<Note>, showFolder: Boolean, empty: String, onOpen: (UUID) -> Unit) {
    if (notes.isEmpty()) {
        EmptyMessage(empty)
        return
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        // Bottom padding keeps the last card clear of the ＋ button.
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 96.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(notes, key = { it.id }) { note ->
            NoteCard(note, showFolder) { onOpen(note.id) }
        }
    }
}

/** Filled, rounded search field — no outline box. */
@Composable
private fun SearchField(query: String, onChange: (String) -> Unit) {
    TextField(
        value = query,
        onValueChange = onChange,
        placeholder = { Text("Search all notes") },
        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onChange("") }) { Icon(Icons.Filled.Close, contentDescription = "Clear search") }
            }
        },
        singleLine = true,
        shape = CircleShape,
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
        ),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

/** Sync icon that turns into a spinner while a sync runs. */
@Composable
private fun SyncButton(status: SyncStatus, onClick: () -> Unit) {
    IconButton(onClick = onClick, enabled = status !is SyncStatus.Syncing) {
        if (status is SyncStatus.Syncing) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
        } else {
            Icon(Icons.Filled.Refresh, contentDescription = "Sync now")
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
private fun NoteCard(note: Note, showFolder: Boolean, onClick: () -> Unit) {
    val preview = remember(note.body) { NotePreview.of(note.body) }
    val edited = editedLabel(note)
    Card(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
            Text(note.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1,
                 overflow = TextOverflow.Ellipsis)
            if (preview.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                Text(preview, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                     maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (showFolder && note.folder.isNotEmpty()) {
                    Text(note.folder, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
                         maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    Text("  ·  ", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(edited, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EditorScreen(vm: NotesViewModel, note: Note) {
    // Local edit state keyed to the note so switching notes resets the fields.
    var title by remember(note.id) { mutableStateOf(vm.displayedTitle(note)) }
    var body by remember(note.id) { mutableStateOf(note.body) }
    var bodyEditor by remember(note.id) { mutableStateOf<LivePreviewEditText?>(null) }
    var confirmDelete by remember(note.id) { mutableStateOf(false) }
    val links = remember(body) { WikiLinkParser.linkedTitles(body) }
    val backlinks = remember(note.id, body) { vm.backlinks(note) }
    val clash by vm.titleClash.collectAsState()
    val titleWarning = clash?.takeIf { it.noteId == note.id }
        ?.let { "A note named “${it.existingTitle}” already exists in this folder." }
    val titleFocus = remember { FocusRequester() }
    var titleFocused by remember { mutableStateOf(false) }
    // A new note opens with the cursor in its empty title.
    LaunchedEffect(note.id) {
        if (vm.freshNoteId.value == note.id) titleFocus.requestFocus()
    }
    BackHandler { vm.select(null) }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete “${note.title}”?") },
            text = { Text("It's removed from this device and, on the next sync, from your other devices.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; vm.delete(note.id) }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {},
                navigationIcon = {
                    IconButton(onClick = { vm.select(null) }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to notes")
                    }
                },
                actions = {
                    IconButton(onClick = { confirmDelete = true }) {
                        Icon(Icons.Filled.Delete, contentDescription = "Delete note")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding()
                .padding(horizontal = 4.dp),
        ) {
            // Title and body are borderless, like the Mac editor: the page is the field.
            // The title commits after a typing pause, when focus leaves it, and on
            // Back, note switches, or backgrounding (see NotesViewModel).
            TextField(
                value = title,
                onValueChange = { title = it; vm.editTitle(note.id, it) },
                placeholder = { Text("Untitled", style = MaterialTheme.typography.headlineSmall) },
                textStyle = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
                singleLine = true,
                isError = titleWarning != null,
                supportingText = titleWarning?.let { { Text(it) } },
                colors = borderlessFieldColors(),
                // Enter moves to the start of the body.
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                keyboardActions = KeyboardActions(onNext = {
                    vm.flushPendingTitle()
                    bodyEditor?.focusAtStart()
                }),
                modifier = Modifier.fillMaxWidth().focusRequester(titleFocus).onFocusChanged {
                    if (titleFocused && !it.isFocused) vm.flushPendingTitle()
                    titleFocused = it.isFocused
                },
            )
            Text(
                listOfNotNull(note.folder.ifEmpty { null }, editedLabel(note)).joinToString("  ·  "),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
            // Live Preview: Markdown styled in place, markers shown only on the cursor lines.
            key(note.id) {
                LivePreviewEditor(
                    initialMarkdown = note.body,
                    onChange = { body = it; vm.updateBody(note.id, it) },
                    onOpenWikiLink = vm::openWikiLink,
                    onReady = { bodyEditor = it },
                    modifier = Modifier.fillMaxWidth().weight(1f),
                )
            }
            if (links.isNotEmpty() || backlinks.isNotEmpty()) {
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainer,
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier.fillMaxWidth().padding(12.dp),
                ) {
                    Column(Modifier.padding(vertical = 8.dp)) {
                        if (links.isNotEmpty()) LinkRow("Links", links, onClick = vm::openWikiLink)
                        if (backlinks.isNotEmpty()) {
                            LinkRow("Backlinks", backlinks.map { it.title }, onClick = vm::openWikiLink)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun borderlessFieldColors() = TextFieldDefaults.colors(
    focusedContainerColor = Color.Transparent,
    unfocusedContainerColor = Color.Transparent,
    focusedIndicatorColor = Color.Transparent,
    unfocusedIndicatorColor = Color.Transparent,
)

/** "3 minutes ago", "Yesterday", "Sep 12" — when the note was last edited. */
private fun editedLabel(note: Note): String =
    DateUtils.getRelativeTimeSpanString(
        note.modifiedAt.toEpochMilli(), System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS,
    ).toString()

@Composable
private fun LinkRow(label: String, titles: List<String>, onClick: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        titles.distinct().take(12).forEach { t ->
            SuggestionChip(onClick = { onClick(t) }, label = { Text(t) })
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
    var showSecret by rememberSaveable { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    val sync by vm.sync.collectAsState()
    BackHandler(onBack = onBack)

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Remove sync credentials?") },
            text = { Text("Sync stops on this device. Your notes stay here and in the bucket.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmClear = false
                    vm.clearCredentials()
                    endpoint = ""; bucket = ""; region = "auto"; accessKey = ""; secret = ""
                }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } },
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sync settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to notes")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "Point Seanboy at your own R2 (or any S3) bucket. Credentials are stored encrypted on this device only.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SettingsField("Endpoint", endpoint, hint = "https://<account>.r2.cloudflarestorage.com",
                                  keyboardType = KeyboardType.Uri) { endpoint = it }
                    SettingsField("Bucket", bucket) { bucket = it }
                    SettingsField("Region", region, hint = "auto") { region = it }
                    SettingsField("Access key ID", accessKey) { accessKey = it }
                    SettingsField(
                        "Secret access key", secret,
                        keyboardType = KeyboardType.Password,
                        hidden = !showSecret,
                        trailing = {
                            TextButton(onClick = { showSecret = !showSecret }) { Text(if (showSecret) "Hide" else "Show") }
                        },
                    ) { secret = it }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(onClick = {
                    vm.saveCredentials(
                        com.torchcodelab.seanboy.core.S3Config(
                            endpoint = endpoint, bucket = bucket,
                            region = region.ifBlank { "auto" },
                            accessKeyID = accessKey, secretAccessKey = secret,
                        ),
                    )
                }) { Text("Save") }
                FilledTonalButton(onClick = vm::syncNow, enabled = sync !is SyncStatus.Syncing) { Text("Sync now") }
                Spacer(Modifier.weight(1f))
                if (existing != null || sync != SyncStatus.NotConfigured) {
                    TextButton(onClick = { confirmClear = true }) {
                        Text("Remove", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
            Surface(
                color = if (sync is SyncStatus.Failed) MaterialTheme.colorScheme.errorContainer
                        else MaterialTheme.colorScheme.surfaceContainer,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(Modifier.padding(horizontal = 4.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (sync is SyncStatus.Syncing) {
                        CircularProgressIndicator(Modifier.padding(start = 12.dp).size(16.dp), strokeWidth = 2.dp)
                    }
                    SyncStatusLine(sync)
                }
            }
        }
    }
}

/** Filled, rounded, borderless field — same family as the search pill. */
@Composable
private fun SettingsField(
    label: String,
    value: String,
    hint: String? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    hidden: Boolean = false,
    trailing: (@Composable () -> Unit)? = null,
    onValueChange: (String) -> Unit,
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        placeholder = hint?.let { { Text(it) } },
        singleLine = true,
        visualTransformation = if (hidden) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, autoCorrectEnabled = false),
        trailingIcon = trailing,
        shape = RoundedCornerShape(12.dp),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
        ),
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
