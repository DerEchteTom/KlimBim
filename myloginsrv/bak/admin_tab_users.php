<?php
// Datei: admin_tab_users.php
// Version: 2025-04-26_01
// Beschreibung: Benutzerverwaltung (Upload, Suche, Bearbeiten, Willkommensmail)

require_once "auth.php";
requireRole('admin');
require_once "mailer_config.php";

date_default_timezone_set('Europe/Berlin');

// DB-Verbindung
$db = new PDO('sqlite:users.db');
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

$info = '';
$error = '';

// ========= POST-VERARBEITUNG =========
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $id = (int)($_POST['id'] ?? 0);
    $action = $_POST['action'] ?? '';

    // Benutzer importieren aus JSON-Datei
    if (isset($_FILES['userfile']) && is_uploaded_file($_FILES['userfile']['tmp_name'])) {
        $data = json_decode(file_get_contents($_FILES['userfile']['tmp_name']), true);
        if (is_array($data)) {
            try {
                $db->beginTransaction();
                $imported = 0;
                foreach ($data as $user) {
                    $username = trim($user['username'] ?? '');
                    $email = trim($user['email'] ?? '');
                    if ($username && $email) {
                        $check = $db->prepare("SELECT COUNT(*) FROM users WHERE username = :u");
                        $check->execute([':u' => $username]);
                        if ($check->fetchColumn() == 0) {
                            $stmt = $db->prepare("INSERT INTO users (username, email, password, role, active) VALUES (:u, :e, '', 'user', 0)");
                            $stmt->execute([':u' => $username, ':e' => $email]);
                            $imported++;
                        }
                    }
                }
                $db->commit();
                $info = "$imported Benutzer erfolgreich importiert.";
            } catch (Exception $e) {
                $db->rollBack();
                $error = "Fehler beim Import: " . $e->getMessage();
            }
        } else {
            $error = "Fehler: Ungültiges JSON-Format.";
        }
    }

    // Bestehenden Benutzer speichern
    if ($action === 'save' && $id) {
        $username = trim($_POST['username'] ?? '');
        $email = trim($_POST['email'] ?? '');
        $password = $_POST['password'] ?? '';
        $role = $_POST['role'] ?? 'user';
        $active = isset($_POST['active']) ? 1 : 0;

        if ($username && $email) {
            $stmt = $db->prepare("UPDATE users SET username = :u, email = :e, role = :r, active = :a WHERE id = :id");
            $stmt->execute([':u' => $username, ':e' => $email, ':r' => $role, ':a' => $active, ':id' => $id]);

            if (!empty($password)) {
                $hash = password_hash($password, PASSWORD_DEFAULT);
                $db->prepare("UPDATE users SET password = :p WHERE id = :id")
                   ->execute([':p' => $hash, ':id' => $id]);
            }

            file_put_contents('audit.log', date('c') . " Benutzer ID $id aktualisiert\n", FILE_APPEND);
            header("Location: " . $_SERVER['PHP_SELF']);
            exit;
        }
    }

    // Benutzer löschen
    if ($action === 'delete' && $id && $id != 1) {
        $db->prepare("DELETE FROM users WHERE id = :id")->execute([':id' => $id]);
        file_put_contents('audit.log', date('c') . " Benutzer ID $id gelöscht\n", FILE_APPEND);
        header("Location: " . $_SERVER['PHP_SELF']);
        exit;
    }

    // Neuen Benutzer anlegen
    if ($action === 'add') {
        $username = trim($_POST['new_username'] ?? '');
        $email = trim($_POST['new_email'] ?? '');
        $password = $_POST['new_password'] ?? '';
        $role = $_POST['new_role'] ?? 'user';
        $active = isset($_POST['new_active']) ? 1 : 0;

        $check = $db->prepare("SELECT COUNT(*) FROM users WHERE username = :u");
        $check->execute([':u' => $username]);
        if ($check->fetchColumn() > 0) {
            $error = "Benutzername '$username' ist bereits vergeben.";
        } else {
            if ($username && $email && $password) {
                $hash = password_hash($password, PASSWORD_DEFAULT);
                $stmt = $db->prepare("INSERT INTO users (username, password, email, role, active) VALUES (:u, :p, :e, :r, :a)");
                $stmt->execute([':u' => $username, ':p' => $hash, ':e' => $email, ':r' => $role, ':a' => $active]);

                file_put_contents('audit.log', date('c') . " Neuer Benutzer $username hinzugefügt\n", FILE_APPEND);

                // Willkommensmail senden
                $server = $_SERVER['HTTP_HOST'] ?? 'localhost';
                $mail = getMailer($email, "Willkommen bei MyLoginServer");
                if ($mail) {
                    $mail->Body = "Hallo $username,\n\nDein Zugang wurde erstellt.\n\nLogin-Adresse: http://$server/login.php\n\nMit freundlichen Gruessen.\n";
                    try {
                        $mail->send();
                    } catch (Exception $e) {
                        file_put_contents('error.log', date('c') . " Fehler beim Willkommensmail an $email: " . $mail->ErrorInfo . "\n", FILE_APPEND);
                    }
                }

                header("Location: " . $_SERVER['PHP_SELF']);
                exit;
            }
        }
    }
}
// ========== POST-VERARBEITUNG ENDE ==========
?>
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <title>Benutzerverwaltung</title>
    <link href="./assets/css/bootstrap.min.css" rel="stylesheet">
    <meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body class="bg-light">
<div class="container-fluid mt-4">

<?php include "admin_tab_nav.php"; ?>

<h4 class="mb-4">Benutzerverwaltung</h4>

<!-- Erfolg- und Fehlermeldungen -->
<?php if (!empty($info)): ?>
    <div class="alert alert-success"><?= htmlspecialchars($info) ?></div>
<?php endif; ?>
<?php if (!empty($error)): ?>
    <div class="alert alert-danger"><?= htmlspecialchars($error) ?></div>
<?php endif; ?>

<!-- Upload- und Suchbereich -->
<div class="row g-2 align-items-center mb-4">
    <div class="col-auto">
        <form method="post" enctype="multipart/form-data" class="d-flex align-items-center">
            <input type="file" name="userfile" accept=".json" class="form-control form-control-sm me-2">
            <button type="submit" class="btn btn-sm btn-primary">Importieren</button>
        </form>
    </div>
    <div class="col-auto d-none d-md-block">
        <div style="width: 20px;"></div>
    </div>
    <div class="col">
        <form method="get" class="d-flex justify-content-end">
            <input type="text" name="search" value="<?= htmlspecialchars($_GET['search'] ?? '') ?>"
                   class="form-control form-control-sm me-2" placeholder="Suche Benutzer/E-Mail">
            <button type="submit" class="btn btn-sm btn-secondary">Suchen</button>
        </form>
    </div>
</div>

<!-- Benutzerliste -->
<div class="table-responsive bg-white rounded shadow-sm p-3">
<table class="table table-sm table-hover align-middle">
<thead class="table-light">
<tr>
    <th>ID</th>
    <th>Benutzername</th>
    <th>E-Mail</th>
    <th>Passwort</th>
    <th>Rolle</th>
    <th>Aktiv</th>
    <th>Aktionen</th>
</tr>
</thead>
<tbody>
<?php
$search = trim($_GET['search'] ?? '');
$stmt = $db->prepare("SELECT * FROM users WHERE username LIKE :s OR email LIKE :s ORDER BY id ASC");
$stmt->execute([':s' => "%$search%"]);
$users = $stmt->fetchAll(PDO::FETCH_ASSOC);
foreach ($users as $u):
?>
<tr>
    <form method="post">
    <td><?= htmlspecialchars($u['id']) ?></td>
    <td><input type="text" name="username" value="<?= htmlspecialchars($u['username']) ?>" class="form-control form-control-sm"></td>
    <td><input type="email" name="email" value="<?= htmlspecialchars($u['email']) ?>" class="form-control form-control-sm"></td>
    <td><input type="password" name="password" placeholder="(neu optional)" class="form-control form-control-sm"></td>
    <td>
        <select name="role" class="form-select form-select-sm">
            <option value="user" <?= $u['role'] === 'user' ? 'selected' : '' ?>>User</option>
            <option value="admin" <?= $u['role'] === 'admin' ? 'selected' : '' ?>>Admin</option>
        </select>
    </td>
    <td class="text-center">
        <input type="checkbox" name="active" value="1" <?= $u['active'] ? 'checked' : '' ?>>
    </td>
    <td>
        <input type="hidden" name="id" value="<?= (int)$u['id'] ?>">
        <button type="submit" name="action" value="save" class="btn btn-sm btn-outline-success">Speichern</button>
        <?php if ($u['id'] != 1): ?>
            <button type="submit" name="action" value="delete" class="btn btn-sm btn-outline-danger">Löschen</button>
        <?php endif; ?>
    </td>
    </form>
</tr>
<?php endforeach; ?>
</tbody>
</table>
</div>

<!-- Neuen Benutzer anlegen -->
<div class="bg-white border rounded p-3 mt-4">
    <h5>Neuen Benutzer hinzufügen</h5>
    <form method="post" class="row g-2 align-items-center">
        <div class="col-md-2">
            <input type="text" name="new_username" placeholder="Benutzername" required class="form-control form-control-sm">
        </div>
        <div class="col-md-3">
            <input type="email" name="new_email" placeholder="E-Mail" required class="form-control form-control-sm">
        </div>
        <div class="col-md-2">
            <input type="password" name="new_password" placeholder="Passwort" required class="form-control form-control-sm">
        </div>
        <div class="col-md-2">
            <select name="new_role" class="form-select form-select-sm">
                <option value="user">User</option>
                <option value="admin">Admin</option>
            </select>
        </div>
        <div class="col-md-1 text-center">
            <input type="checkbox" name="new_active" value="1" checked>
        </div>
        <div class="col-md-2">
            <button type="submit" name="action" value="add" class="btn btn-sm btn-outline-success w-100">Anlegen</button>
        </div>
    </form>
</div>

</div> <!-- container -->
</body>
</html>
