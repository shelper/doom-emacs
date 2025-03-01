;;; core.el --- the heart of the beast -*- lexical-binding: t; -*-

(when (< emacs-major-version 27)
  (error "Detected Emacs %s. Minimum supported version is 27.1."
         emacs-version))

;; Ensure Doom's core libraries are visible for loading
(add-to-list 'load-path (file-name-directory load-file-name))

;; Remember these variables' initial values, so we can safely reset them at a
;; later time, or consult them without fear of contamination.
(dolist (var '(exec-path load-path process-environment))
  (unless (get var 'initial-value)
    (put var 'initial-value (default-value var))))

;; Just the... bear necessities~
(require 'core-lib)


;;
;;; Initialize internal state

(defgroup doom nil
  "An Emacs framework for the stubborn martian hacker."
  :link '(url-link "https://doomemacs.org"))

(defconst doom-version "3.0.0-dev"
  "Current version of Doom Emacs core.")

(defconst doom-modules-version "22.03.0-dev"
  "Current version of Doom Emacs.")

(defvar doom-debug-p (or (getenv-internal "DEBUG") init-file-debug)
  "If non-nil, Doom will log more.

Use `doom-debug-mode' to toggle it. The --debug-init flag and setting the DEBUG
envvar will enable this at startup.")

(defvar doom-init-p nil
  "Non-nil if Doom has been initialized.")

(defvar doom-init-time nil
  "The time it took, in seconds, for Doom Emacs to initialize.")

(defconst doom-interactive-p (not noninteractive)
  "If non-nil, Emacs is in interactive mode.")

(defconst NATIVECOMP (if (fboundp 'native-comp-available-p) (native-comp-available-p)))
(defconst EMACS28+   (> emacs-major-version 27))
(defconst EMACS29+   (> emacs-major-version 28))
(defconst IS-MAC     (eq system-type 'darwin))
(defconst IS-LINUX   (eq system-type 'gnu/linux))
(defconst IS-WINDOWS (memq system-type '(cygwin windows-nt ms-dos)))
(defconst IS-BSD     (or IS-MAC (eq system-type 'berkeley-unix)))

(when-let (realhome
           (and IS-WINDOWS
                (null (getenv-internal "HOME"))
                (getenv "USERPROFILE")))
  (setenv "HOME" realhome)
  (setq abbreviated-home-dir nil))


;;
;;; Directory variables

(defconst doom-emacs-dir user-emacs-directory
  "The path to the currently loaded .emacs.d directory. Must end with a slash.")

(defconst doom-core-dir (concat doom-emacs-dir "core/")
  "The root directory of Doom's core files. Must end with a slash.")

(defconst doom-modules-dir (concat doom-emacs-dir "modules/")
  "The root directory for Doom's modules. Must end with a slash.")

(defconst doom-local-dir
  (if-let (localdir (getenv-internal "DOOMLOCALDIR"))
      (expand-file-name (file-name-as-directory localdir))
    (concat doom-emacs-dir ".local/"))
  "Root directory for local storage.

Use this as a storage location for this system's installation of Doom Emacs.

These files should not be shared across systems. By default, it is used by
`doom-etc-dir' and `doom-cache-dir'. Must end with a slash.")

(defconst doom-etc-dir (concat doom-local-dir "etc/")
  "Directory for non-volatile local storage.

Use this for files that don't change much, like server binaries, external
dependencies or long-term shared data. Must end with a slash.")

(defconst doom-cache-dir (concat doom-local-dir "cache/")
  "Directory for volatile local storage.

Use this for files that change often, like cache files. Must end with a slash.")

(defconst doom-docs-dir (concat doom-emacs-dir "docs/")
  "Where Doom's documentation files are stored. Must end with a slash.")

(defconst doom-private-dir
  (if-let (doomdir (getenv-internal "DOOMDIR"))
      (expand-file-name (file-name-as-directory doomdir))
    (or (let ((xdgdir
               (expand-file-name "doom/"
                                 (or (getenv-internal "XDG_CONFIG_HOME")
                                     "~/.config"))))
          (if (file-directory-p xdgdir) xdgdir))
        "~/.doom.d/"))
  "Where your private configuration is placed.

Defaults to ~/.config/doom, ~/.doom.d or the value of the DOOMDIR envvar;
whichever is found first. Must end in a slash.")

(defconst doom-autoloads-file
  (concat doom-local-dir "autoloads." emacs-version ".el")
  "Where `doom-reload-core-autoloads' stores its core autoloads.

This file is responsible for informing Emacs where to find all of Doom's
autoloaded core functions (in core/autoload/*.el).")

(defconst doom-env-file (concat doom-local-dir "env")
  "The location of your envvar file, generated by `doom env`.

This file contains environment variables scraped from your shell environment,
which is loaded at startup (if it exists). This is helpful if Emacs can't
\(easily) be launched from the correct shell session (particularly for MacOS
users).")


;;
;;; Custom error types

(define-error 'doom-error "Error in Doom Emacs core")
(define-error 'doom-hook-error "Error in a Doom startup hook" 'doom-error)
(define-error 'doom-autoload-error "Error in Doom's autoloads file" 'doom-error)
(define-error 'doom-module-error "Error in a Doom module" 'doom-error)
(define-error 'doom-private-error "Error in private config" 'doom-error)
(define-error 'doom-package-error "Error with packages" 'doom-error)


;;
;;; Custom hooks

(defvar doom-first-input-hook nil
  "Transient hooks run before the first user input.")
(put 'doom-first-input-hook 'permanent-local t)

(defvar doom-first-file-hook nil
  "Transient hooks run before the first interactively opened file.")
(put 'doom-first-file-hook 'permanent-local t)

(defvar doom-first-buffer-hook nil
  "Transient hooks run before the first interactively opened buffer.")
(put 'doom-first-buffer-hook 'permanent-local t)

(defvar doom-after-reload-hook nil
  "A list of hooks to run after `doom/reload' has reloaded Doom.")

(defvar doom-before-reload-hook nil
  "A list of hooks to run before `doom/reload' has reloaded Doom.")


;;
;;; Native Compilation support (http://akrl.sdf.org/gccemacs.html)

(when NATIVECOMP
  ;; Don't store eln files in ~/.emacs.d/eln-cache (they are likely to be purged
  ;; when upgrading Doom).
  (add-to-list 'native-comp-eln-load-path (concat doom-cache-dir "eln/"))

  (with-eval-after-load 'comp
    ;; HACK Disable native-compilation for some troublesome packages
    (mapc (doom-partial #'add-to-list 'native-comp-deferred-compilation-deny-list)
          (let ((local-dir-re (concat "\\`" (regexp-quote doom-local-dir))))
            (list (concat local-dir-re ".*/emacs-jupyter.*\\.el\\'")
                  (concat local-dir-re ".*/evil-collection-vterm\\.el\\'")
                  (concat local-dir-re ".*/with-editor\\.el\\'"))))))


;;
;;; Don't litter `doom-emacs-dir'

;; We avoid `no-littering' because it's a mote too opinionated for our needs.
(setq async-byte-compile-log-file  (concat doom-etc-dir "async-bytecomp.log")
      custom-file                  (concat doom-private-dir "custom.el")
      desktop-dirname              (concat doom-etc-dir "desktop")
      desktop-base-file-name       "autosave"
      desktop-base-lock-name       "autosave-lock"
      pcache-directory             (concat doom-cache-dir "pcache/")
      request-storage-directory    (concat doom-cache-dir "request")
      shared-game-score-directory  (concat doom-etc-dir "shared-game-score/"))

(defadvice! doom--write-to-sane-paths-a (fn &rest args)
  "Write 3rd party files to `doom-etc-dir' to keep `user-emacs-directory' clean.

Also writes `put' calls for saved safe-local-variables to `custom-file' instead
of `user-init-file' (which `en/disable-command' in novice.el.gz is hardcoded to
do)."
  :around #'en/disable-command
  :around #'locate-user-emacs-file
  (let ((user-emacs-directory doom-etc-dir)
        (user-init-file custom-file))
    (apply fn args)))


;;
;;; MODE-local-vars-hook

;; File+dir local variables are initialized after the major mode and its hooks
;; have run. If you want hook functions to be aware of these customizations, add
;; them to MODE-local-vars-hook instead.
(defvar doom-inhibit-local-var-hooks nil)

(defun doom-run-local-var-hooks-h ()
  "Run MODE-local-vars-hook after local variables are initialized."
  (unless doom-inhibit-local-var-hooks
    (setq-local doom-inhibit-local-var-hooks t)
    (doom-run-hooks (intern (format "%s-local-vars-hook" major-mode)))))

;; If the user has disabled `enable-local-variables', then
;; `hack-local-variables-hook' is never triggered, so we trigger it at the end
;; of `after-change-major-mode-hook':
(defun doom-run-local-var-hooks-maybe-h ()
  "Run `doom-run-local-var-hooks-h' if `enable-local-variables' is disabled."
  (unless enable-local-variables
    (doom-run-local-var-hooks-h)))


;;
;;; Reasonable defaults

;; Emacs is essentially one huge security vulnerability, what with all the
;; dependencies it pulls in from all corners of the globe. Let's try to be at
;; least a little more discerning.
(setq gnutls-verify-error (and (fboundp 'gnutls-available-p)
                               (gnutls-available-p)
                               (not (getenv-internal "INSECURE")))
      gnutls-algorithm-priority
      (when (boundp 'libgnutls-version)
        (concat "SECURE128:+SECURE192:-VERS-ALL"
                (if (and (not IS-WINDOWS)
                         (>= libgnutls-version 30605))
                    ":+VERS-TLS1.3")
                ":+VERS-TLS1.2"))
      ;; `gnutls-min-prime-bits' is set based on recommendations from
      ;; https://www.keylength.com/en/4/
      gnutls-min-prime-bits 3072
      tls-checktrust gnutls-verify-error
      ;; Emacs is built with `gnutls' by default, so `tls-program' would not be
      ;; used in that case. Otherwise, people have reasons to not go with
      ;; `gnutls', we use `openssl' instead. For more details, see
      ;; https://redd.it/8sykl1
      tls-program '("openssl s_client -connect %h:%p -CAfile %t -nbio -no_ssl3 -no_tls1 -no_tls1_1 -ign_eof"
                    "gnutls-cli -p %p --dh-bits=3072 --ocsp --x509cafile=%t \
--strict-tofu --priority='SECURE192:+SECURE128:-VERS-ALL:+VERS-TLS1.2:+VERS-TLS1.3' %h"
                    ;; compatibility fallbacks
                    "gnutls-cli -p %p %h"))

;; Emacs stores `authinfo' in $HOME and in plain-text. Let's not do that, mkay?
;; This file stores usernames, passwords, and other such treasures for the
;; aspiring malicious third party.
(setq auth-sources (list (concat doom-etc-dir "authinfo.gpg")
                         "~/.authinfo.gpg"))

;; A second, case-insensitive pass over `auto-mode-alist' is time wasted, and
;; indicates misconfiguration (don't rely on case insensitivity for file names).
(setq auto-mode-case-fold nil)

;; Disable bidirectional text scanning for a modest performance boost. I've set
;; this to `nil' in the past, but the `bidi-display-reordering's docs say that
;; is an undefined state and suggest this to be just as good:
(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right)

;; Disabling the BPA makes redisplay faster, but might produce incorrect display
;; reordering of bidirectional text with embedded parentheses and other bracket
;; characters whose 'paired-bracket' Unicode property is non-nil.
(setq bidi-inhibit-bpa t)  ; Emacs 27 only

;; Reduce rendering/line scan work for Emacs by not rendering cursors or regions
;; in non-focused windows.
(setq-default cursor-in-non-selected-windows nil)
(setq highlight-nonselected-windows nil)

;; More performant rapid scrolling over unfontified regions. May cause brief
;; spells of inaccurate syntax highlighting right after scrolling, which should
;; quickly self-correct.
(setq fast-but-imprecise-scrolling t)

;; Don't ping things that look like domain names.
(setq ffap-machine-p-known 'reject)

;; Resizing the Emacs frame can be a terribly expensive part of changing the
;; font. By inhibiting this, we halve startup times, particularly when we use
;; fonts that are larger than the system default (which would resize the frame).
(setq frame-inhibit-implied-resize t)

;; The GC introduces annoying pauses and stuttering into our Emacs experience,
;; so we use `gcmh' to stave off the GC while we're using Emacs, and provoke it
;; when it's idle. However, if the idle delay is too long, we run the risk of
;; runaway memory usage in busy sessions. If it's too low, then we may as well
;; not be using gcmh at all.
(setq gcmh-idle-delay 'auto  ; default is 15s
      gcmh-auto-idle-delay-factor 10
      gcmh-high-cons-threshold (* 16 1024 1024))  ; 16mb

;; Emacs "updates" its ui more often than it needs to, so slow it down slightly
(setq idle-update-delay 1.0)  ; default is 0.5

;; Font compacting can be terribly expensive, especially for rendering icon
;; fonts on Windows. Whether disabling it has a notable affect on Linux and Mac
;; hasn't been determined, but do it there anyway, just in case. This increases
;; memory usage, however!
(setq inhibit-compacting-font-caches t)

;; PGTK builds only: this timeout adds latency to frame operations, like
;; `make-frame-invisible', which are frequently called without a guard because
;; it's inexpensive in non-PGTK builds. Lowering the timeout from the default
;; 0.1 should make childframes and packages that manipulate them (like `lsp-ui',
;; `company-box', and `posframe') feel much snappier. See emacs-lsp/lsp-ui#613.
(setq pgtk-wait-for-event-timeout 0.001)

;; Increase how much is read from processes in a single chunk (default is 4kb).
;; This is further increased elsewhere, where needed (like our LSP module).
(setq read-process-output-max (* 64 1024))  ; 64kb

;; Introduced in Emacs HEAD (b2f8c9f), this inhibits fontification while
;; receiving input, which should help a little with scrolling performance.
(setq redisplay-skip-fontification-on-input t)

;; Performance on Windows is considerably worse than elsewhere. We'll need
;; everything we can get.
(when (boundp 'w32-get-true-file-attributes)
  (setq w32-get-true-file-attributes nil   ; decrease file IO workload
        w32-pipe-read-delay 0              ; faster IPC
        w32-pipe-buffer-size (* 64 1024))  ; read more at a time (was 4K)

  ;; The clipboard on Windows could be in another encoding (likely utf-16), so
  ;; let Emacs/the OS decide what to use there.
  (setq selection-coding-system 'utf-8))

;; Remove command line options that aren't relevant to our current OS; means
;; slightly less to process at startup.
(unless IS-MAC    (setq command-line-ns-option-alist nil))
(unless IS-LINUX  (setq command-line-x-option-alist nil))

;; HACK `tty-run-terminal-initialization' is *tremendously* slow for some
;;      reason; inexplicably doubling startup time for terminal Emacs. Keeping
;;      it disabled will have nasty side-effects, so we simply delay it instead,
;;      and invoke it later, at which point it runs quickly; how mysterious!
(unless (daemonp)
  (advice-add #'tty-run-terminal-initialization :override #'ignore)
  (add-hook! 'window-setup-hook
    (defun doom-init-tty-h ()
      (advice-remove #'tty-run-terminal-initialization #'ignore)
      (tty-run-terminal-initialization (selected-frame) nil t))))


;;
;;; Reasonable defaults for interactive sessions

;; Disable warnings from legacy advice system. They aren't useful, and what can
;; we do about them, besides changing packages upstream?
(setq ad-redefinition-action 'accept)

;; Reduce debug output, well, unless we've asked for it.
(setq debug-on-error init-file-debug
      jka-compr-verbose init-file-debug)

;; Get rid of "For information about GNU Emacs..." message at startup, unless
;; we're in a daemon session where it'll say "Starting Emacs daemon." instead,
;; which isn't so bad.
(unless (daemonp)
  (advice-add #'display-startup-echo-area-message :override #'ignore))

;; Reduce *Message* noise at startup. An empty scratch buffer (or the dashboard)
;; is more than enough.
(setq inhibit-startup-screen t
      inhibit-startup-echo-area-message user-login-name
      inhibit-default-init t
      ;; Shave seconds off startup time by starting the scratch buffer in
      ;; `fundamental-mode', rather than, say, `org-mode' or `text-mode', which
      ;; pull in a ton of packages. `doom/open-scratch-buffer' provides a better
      ;; scratch buffer anyway.
      initial-major-mode 'fundamental-mode
      initial-scratch-message nil)


;;
;;; Incremental lazy-loading

(defvar doom-incremental-packages '(t)
  "A list of packages to load incrementally after startup. Any large packages
here may cause noticeable pauses, so it's recommended you break them up into
sub-packages. For example, `org' is comprised of many packages, and can be
broken up into:

  (doom-load-packages-incrementally
   '(calendar find-func format-spec org-macs org-compat
     org-faces org-entities org-list org-pcomplete org-src
     org-footnote org-macro ob org org-clock org-agenda
     org-capture))

This is already done by the lang/org module, however.

If you want to disable incremental loading altogether, either remove
`doom-load-packages-incrementally-h' from `emacs-startup-hook' or set
`doom-incremental-first-idle-timer' to nil. Incremental loading does not occur
in daemon sessions (they are loaded immediately at startup).")

(defvar doom-incremental-first-idle-timer 2.0
  "How long (in idle seconds) until incremental loading starts.

Set this to nil to disable incremental loading.")

(defvar doom-incremental-idle-timer 0.75
  "How long (in idle seconds) in between incrementally loading packages.")

(defvar doom-incremental-load-immediately (daemonp)
  "If non-nil, load all incrementally deferred packages immediately at startup.")

(defun doom-load-packages-incrementally (packages &optional now)
  "Registers PACKAGES to be loaded incrementally.

If NOW is non-nil, load PACKAGES incrementally, in `doom-incremental-idle-timer'
intervals."
  (if (not now)
      (appendq! doom-incremental-packages packages)
    (while packages
      (let* ((gc-cons-threshold most-positive-fixnum)
             (req (pop packages)))
        (unless (featurep req)
          (doom-log "Incrementally loading %s" req)
          (condition-case-unless-debug e
              (or (while-no-input
                    ;; If `default-directory' is a directory that doesn't exist
                    ;; or is unreadable, Emacs throws up file-missing errors, so
                    ;; we set it to a directory we know exists and is readable.
                    (let ((default-directory doom-emacs-dir)
                          (inhibit-message t)
                          file-name-handler-alist)
                      (require req nil t))
                    t)
                  (push req packages))
            (error
             (message "Failed to load %S package incrementally, because: %s"
                      req e)))
          (if (not packages)
              (doom-log "Finished incremental loading")
            (run-with-idle-timer doom-incremental-idle-timer
                                 nil #'doom-load-packages-incrementally
                                 packages t)
            (setq packages nil)))))))

(defun doom-load-packages-incrementally-h ()
  "Begin incrementally loading packages in `doom-incremental-packages'.

If this is a daemon session, load them all immediately instead."
  (if doom-incremental-load-immediately
      (mapc #'require (cdr doom-incremental-packages))
    (when (numberp doom-incremental-first-idle-timer)
      (run-with-idle-timer doom-incremental-first-idle-timer
                           nil #'doom-load-packages-incrementally
                           (cdr doom-incremental-packages) t))))


;;
;;; Fixes/hacks

;; Produce more helpful (and visible) error messages from errors emitted from
;; hooks (particularly mode hooks, that usually go unnoticed otherwise.
(advice-add #'run-hooks :override #'doom-run-hooks)


;;
;;; Bootstrapper

(defun doom-display-benchmark-h (&optional return-p)
  "Display a benchmark including number of packages and modules loaded.

If RETURN-P, return the message as a string instead of displaying it."
  (funcall (if return-p #'format #'message)
           "Doom loaded %d packages across %d modules in %.03fs"
           (- (length load-path) (length (get 'load-path 'initial-value)))
           (if doom-modules (hash-table-count doom-modules) 0)
           (or doom-init-time
               (setq doom-init-time
                     (float-time (time-subtract (current-time) before-init-time))))))

(defun doom-initialize (&optional force-p)
  "Bootstrap Doom, if it hasn't already (or if FORCE-P is non-nil).

The bootstrap process ensures that everything Doom needs to run is set up;
essential directories exist, core packages are installed, `doom-autoloads-file'
is loaded (failing if it isn't), that all the needed hooks are in place, and
that `core-packages' will load when `package' or `straight' is used.

The overall load order of Doom is as follows:

  ~/.emacs.d/init.el
  ~/.emacs.d/core/core.el
  ~/.doom.d/init.el
  Module init.el files
  `doom-init-modules-hook'
  Module config.el files
  `doom-configure-modules-hook'
  ~/.doom.d/config.el
  `after-init-hook'
  `emacs-startup-hook'
  `doom-init-ui-hook'
  `window-setup-hook'

Module load order is determined by your `doom!' block. See `doom-modules-dirs'
for a list of all recognized module trees. Order defines precedence (from most
to least)."
  (when (or force-p (not doom-init-p))
    (setq doom-init-p t)
    (doom-log "Initializing Doom")

    ;; Reset as much state as possible, so `doom-initialize' can be treated like
    ;; a reset function. e.g. when reloading the config.
    (dolist (var '(exec-path load-path))
      (set-default var (get var 'initial-value)))

    ;; Doom caches a lot of information in `doom-autoloads-file'. Module and
    ;; package autoloads, autodefs like `set-company-backend!', and variables
    ;; like `doom-modules', `doom-disabled-packages', `load-path',
    ;; `auto-mode-alist', and `Info-directory-list'. etc. Compiling them into
    ;; one place is a big reduction in startup time.
    (condition-case-unless-debug e
        ;; Avoid `file-name-sans-extension' for premature optimization reasons.
        ;; `string-remove-suffix' is cheaper because it performs no file sanity
        ;; checks; just plain ol' string manipulation.
        (load (string-remove-suffix ".el" doom-autoloads-file) nil 'nomessage)
      (file-missing
       ;; If the autoloads file fails to load then the user forgot to sync, or
       ;; aborted a doom command midway!
       (if (locate-file doom-autoloads-file load-path)
           ;; Something inside the autoloads file is triggering this error;
           ;; forward it to the caller!
           (signal 'doom-autoload-error e)
         (signal 'doom-error
                 (list "Doom is in an incomplete state"
                       "run 'doom sync' on the command line to repair it")))))

    (if doom-debug-p (doom-debug-mode +1))

    ;; Load shell environment, optionally generated from 'doom env'. No need
    ;; to do so if we're in terminal Emacs, where Emacs correctly inherits
    ;; your shell environment.
    (when (and (or (display-graphic-p)
                   (daemonp))
               doom-env-file)
      (setq-default process-environment (get 'process-environment 'initial-value))
      (doom-load-envvars-file doom-env-file 'noerror))

    ;; Loads `use-package' and all the helper macros modules (and users) can use
    ;; to configure their packages.
    (require 'core-modules)

    ;; There's a chance the user will later use package.el or straight in this
    ;; interactive session. If they do, make sure they're properly initialized
    ;; when they do.
    (autoload 'doom-initialize-packages "core-packages")
    (eval-after-load 'package '(require 'core-packages))
    (eval-after-load 'straight '(doom-initialize-packages))

    (unless noninteractive
      ;; Bootstrap the interactive session
      (add-hook 'after-change-major-mode-hook #'doom-run-local-var-hooks-maybe-h 100)
      (add-hook 'hack-local-variables-hook #'doom-run-local-var-hooks-h)
      (add-hook 'emacs-startup-hook #'doom-load-packages-incrementally-h)
      (add-hook 'window-setup-hook #'doom-display-benchmark-h)
      (doom-run-hook-on 'doom-first-buffer-hook '(find-file-hook doom-switch-buffer-hook))
      (doom-run-hook-on 'doom-first-file-hook   '(find-file-hook dired-initial-position-hook))
      (doom-run-hook-on 'doom-first-input-hook  '(pre-command-hook))

      (add-hook 'doom-first-buffer-hook #'gcmh-mode)))

  doom-init-p)

(provide 'core)
;;; core.el ends here
