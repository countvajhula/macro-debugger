
(module prefs mzscheme
  (require (lib "framework.ss" "framework"))
  (provide (all-defined))

  (define current-syntax-font-size (make-parameter 16))
  (define current-default-columns (make-parameter 40))

  (define-syntax pref:get/set
    (syntax-rules ()
      [(_ get/set prop)
       (define get/set
         (case-lambda
           [() (preferences:get 'prop)]
           [(newval) (preferences:set 'prop newval)]))]))

  (preferences:set-default 'SyntaxBrowser:Width 700 number?)
  (preferences:set-default 'SyntaxBrowser:Height 600 number?)
  (preferences:set-default 'SyntaxBrowser:PropertiesPanelPercentage 1/3 number?)
  (preferences:set-default 'SyntaxBrowser:PropertiesPanelShown #t boolean?)

  (pref:get/set pref:width SyntaxBrowser:Width)
  (pref:get/set pref:height SyntaxBrowser:Height)
  (pref:get/set pref:props-percentage SyntaxBrowser:PropertiesPanelPercentage)
  (pref:get/set pref:props-shown? SyntaxBrowser:PropertiesPanelShown)
  
  )