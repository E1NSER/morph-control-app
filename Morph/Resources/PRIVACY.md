# Datenschutzhinweise für Morph Control

Vorläufige Hinweise zur lokalen Version, Stand 30. Oktober 2026.

Morph Control ist eine unabhängige macOS-App zur Steuerung einer Dyson Solarcycle Morph. Es gibt keinen Morph Control-Server, keine Werbung und keine eingebauten Analyse-SDKs.

## Verantwortliche Stelle

Sacha Eisner / E1NSER, Arnsteingasse 26/36, 1150 Wien, Österreich.

Kontakt: support@einser.at.

## Einrichtung über Dyson

Um den Lampenschlüssel abzurufen, sendet Morph Control das gewählte Land, deine E-Mail-Adresse, dein Passwort und den per E-Mail erhaltenen Einmalcode über HTTPS direkt an die Dyson-Konto-Schnittstelle. Dyson erhält diese Daten und verarbeitet sie nach seinen eigenen Datenschutzbedingungen. Die Einrichtung verwendet die undokumentierte Schnittstelle der MyDyson-App.

Passwort, Einmalcode und temporäre Anmeldetoken werden nur für diesen Einrichtungsvorgang benötigt und nicht als Kontozugang gespeichert. Die App benötigt kein zusätzliches Morph Control-Konto.

## Lokale Steuerung und Speicherung

Nach der Einrichtung kommuniziert Morph Control über Bluetooth direkt mit der Lampe. Dazu benötigt die App deine macOS-Bluetooth-Freigabe. Der Lampenschlüssel wird im macOS-Schlüsselbund gespeichert. Gerätezuordnung und App-Einstellungen werden lokal verwahrt. Die normale Lichtsteuerung benötigt keinen Morph Control-Server und keine Internetverbindung.

Darstellung, Akzentfarbe, ein eigener Farbcode und die Verbindungseinstellungen `connection.keepAlive` und `connection.syncPowerWithMac` werden ausschließlich in den lokalen App-Einstellungen (UserDefaults der App) gespeichert. Diese Präferenzen werden nicht an Dyson oder einen anderen Dienst übertragen. Über „Zurücksetzen“ im Erscheinungsbild stellst du die Standardauswahl der Darstellung wieder her; die Verbindungseinstellung wird separat über ihre Option geändert.

Auch die gewählte App-Sprache (System, Deutsch oder English) wird ausschließlich lokal unter `morph.language` gespeichert. Eine Sprachänderung verändert weder die gespeicherte Kopplung noch dein Dyson-Konto.

„Verbindung aufrechterhalten“ ist standardmäßig aktiv. Die App versucht mit gespeicherter Lampe beim Start einmal eine Bluetooth-Verbindung und hält sie auch bei geschlossenem Steuerpanel. Bei ausgeschalteter Option wird eine unbenutzte Verbindung nach 60 Sekunden bei geschlossenen Steueransichten freigegeben. Manuelles Freigeben pausiert die automatische Verbindung bis zum expliziten Verbinden, erneutem Aktivieren der Option oder App-Neustart. Die Pause bleibt nur für die laufende App-Sitzung im Speicher. Beim Schlafen wird getrennt. Beim Aufwachen oder unerwartetem Verbindungsabbruch erfolgen höchstens zwei Versuche pro Wiederherstellungsphase, wenn die Verbindung benötigt wird und keine manuelle Pause gesetzt ist. Eine bekannte Gerätekennung wird nur während des App-Prozesses im Arbeitsspeicher als Suchhilfe gehalten. Bei Bildschirmrückkehr oder erneuter Bedienung kann eine länger nicht bestätigte Sitzung durch eine lokale Statusabfrage geprüft werden. Diese Verbindungsverwaltung benötigt keinen zusätzlichen Cloud-Dienst und führt keine endlose Fehler-Wiederholung aus.

Die lokale Option „Licht mit dem Mac schalten“ (`connection.syncPowerWithMac`) ist standardmäßig ausgeschaltet. Aktiviert nutzt sie App-Start und Aufwachen zum einmaligen Verbinden und Einschalten, auch bei ausgeschaltetem Keep-Alive. Vor Schlafen oder System-Shutdown versucht die App nur über eine bereits aktive Verbindung auszuschalten; dafür wird nicht neu verbunden. Eine manuelle Verbindungspause unterbindet die Automatik. Normales App-Beenden trennt ohne Ausschalten. Die Option aktiviert kein Anmeldeobjekt und keine zusätzliche Kontoverknüpfung; für den Start nach der Anmeldung muss „Bei Anmeldung starten“ gesondert freiwillig gewählt werden. macOS kann einen Ausschaltbefehl beim Einschlafen oder Herunterfahren unterbrechen.

Über „Lampe vergessen“ können die gespeicherte Zuordnung und der zugehörige Schlüssel entfernt werden. Die Bluetooth-Freigabe lässt sich in „Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth“ widerrufen. Eine freiwillig aktivierte Anmeldung beim Systemstart kann in „Allgemein → Anmeldeobjekte“ ausgeschaltet werden.

## Entwicklungsstand

Die Einrichtung und Grundsteuerung wurden mit einer echten Solarcycle Morph geprüft. Weitere Geräte und Betriebssystemversionen sowie das endgültige Distributionspaket müssen vor einer Veröffentlichung geprüft werden. Die öffentliche Datenschutz-URL steht noch aus; diese lokale Ressource ist noch keine veröffentlichte Store-Datenschutzerklärung.

Support: support@einser.at.

Morph Control ist nicht mit Dyson verbunden und wird nicht von Dyson unterstützt.
