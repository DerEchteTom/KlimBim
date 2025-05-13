<?php
// Datei: admin_tab_mailtest.php – Version: 2025-05-08_01
date_default_timezone_set('Europe/Berlin');
require_once "auth.php";
requireRole('admin');
require_once 'config_support.php';

$env_file = '.env';
$backup_file = '.env.bak';
$notice = '';
$test_notice = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['send_test'])) {
    $recipient = trim($_POST['test_email'] ?? '');
    if (!filter_var($recipient, FILTER_VALIDATE_EMAIL)) {
        $test_notice = "❌ Ungültige E-Mail-Adresse.";
    } else {
        $mail = getConfiguredMailer();
        if ($mail) {
            try {
                $mail->addAddress($recipient);
                $mail->Subject = "Testmail";
                $mail->Body = "Dies ist eine automatisch generierte Testmail.";
                $mail->send();
                $test_notice = "✅ Testmail erfolgreich gesendet an $recipient.";
                logAction("audit.log", "Testmail an $recipient gesendet.");
            } catch (Exception $e) {
                $test_notice = "❌ Fehler beim Senden: " . $mail->ErrorInfo;
                logAction("error.log", "Fehler beim Senden an $recipient: " . $mail->ErrorInfo);
            }
        } else {
            $test_notice = "❌ Mailer konnte nicht initialisiert werden.";
        }
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['env_save'])) {
    $assoc = parseRawEnv($_POST['env'] ?? '');
    saveEnvFile($env_file, $assoc, false);
    $notice = "Datei gespeichert.";
    logAction("audit.log", "admin_tab_mailtest.php: .env gespeichert.");
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['env_encrypt'])) {
    $raw = $_POST['env'] ?? '';
    file_put_contents($backup_file, $raw);
    $assoc = parseRawEnv($raw);
    $key = getEncryptionKey();
    foreach ($assoc as $k => $v) {
        if (in_array($k, ['SMTP_HOST', 'SMTP_FROM', 'ADMIN_EMAIL'], true) && !isEncrypted($v) && !empty($v)) {
            $assoc[$k] = encryptValue($v, $key, 'XOR');
        }
    }
    saveEnvFile($env_file, $assoc, true);
    $notice = "Sensible Felder verschlüsselt. Backup gespeichert unter .env.bak.";
    logAction("audit.log", "admin_tab_mailtest.php: Verschlüsselung durchgeführt.");
}

$env = parseEnvFile();
$key = getEncryptionKey();
?>
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <title>SMTP-Mailtest & Konfiguration</title>
    <link href="./assets/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="container-fluid mt-4">
<?php include 'admin_tab_nav.php'; ?>
<div class="container">
    <h3>SMTP-Test & Konfiguration</h3>

    <form method="post" class="mb-3 d-flex gap-2">
        <input type="email" name="test_email" placeholder="E-Mail-Adresse" required class="form-control w-auto" style="min-width:320px">
        <button type="submit" name="send_test" class="btn btn-primary">Testmail senden</button>
    </form>
    <?php if (!empty($test_notice)): ?>
        <div class="alert alert-info"><?= htmlspecialchars($test_notice) ?></div>
    <?php endif; ?>

    <h4 class="mt-5">.env bearbeiten / verschlüsseln</h4>
    <?php if (!empty($notice)): ?>
        <div class="alert alert-info"><?= htmlspecialchars($notice) ?></div>
    <?php endif; ?>
    <form method="post" class="mb-3">
        <textarea name="env" rows="14" class="form-control font-monospace"><?= htmlspecialchars(file_get_contents($env_file)) ?></textarea>
        <div class="d-flex gap-2 mt-2">
            <button type="submit" name="env_save" class="btn btn-secondary">Nur speichern</button>
            <button type="submit" name="env_encrypt" class="btn btn-warning">Jetzt verschlüsseln</button>
        </div>
    </form>

    <hr class="my-4">
    <h5>Entschlüsselte ENV-Werte:</h5>
    <table class="table table-bordered table-sm bg-light">
        <thead><tr><th>Schlüssel</th><th>Wert (entschlüsselt)</th></tr></thead>
        <tbody>
        <?php foreach ($env as $k => $v): ?>
            <tr><td><?= htmlspecialchars($k) ?></td><td><?= htmlspecialchars(decryptValue($v, $key)) ?></td></tr>
        <?php endforeach; ?>
        </tbody>
    </table>
</div>
</body>
</html>