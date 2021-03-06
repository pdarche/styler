/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 2.0/LGPL 2.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is Ajax.org Code Editor (ACE).
 *
 * The Initial Developer of the Original Code is
 * Ajax.org B.V.
 * Portions created by the Initial Developer are Copyright (C) 2010
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *      Fabian Jakobs <fabian AT ajax DOT org>
 *
 * Alternatively, the contents of this file may be used under the terms of
 * either the GNU General Public License Version 2 or later (the "GPL"), or
 * the GNU Lesser General Public License Version 2.1 or later (the "LGPL"),
 * in which case the provisions of the GPL or the LGPL are applicable instead
 * of those above. If you wish to allow use of your version of this file only
 * under the terms of either the GPL or the LGPL, and not to allow others to
 * use your version of this file under the terms of the MPL, indicate your
 * decision by deleting the provisions above and replace them with the notice
 * and other provisions required by the GPL or the LGPL. If you do not delete
 * the provisions above, a recipient may use your version of this file under
 * the terms of any one of the MPL, the GPL or the LGPL.
 *
 * ***** END LICENSE BLOCK ***** */
 
define(function(require, exports, module) {
    
var oop = require("ace/lib/oop");
var Mirror = require("ace/worker/mirror").Mirror;
var CSSLint = require("ace/mode/css/csslint").CSSLint;
var getStats = require("../../lib/editor/cssstats");

var Worker = exports.Worker = function(sender) {
    Mirror.call(this, sender);
    this.setTimeout(200);
    this.statsTimeout = 0;
    this.updateStats = Worker.prototype.updateStats.bind(this);
    this.previousStats = null;
    this.rules = {};
    this.sender.on("csslintconf", (function(e){
      this.rules = {};
      for (var i in e.data){
          if(e.data[i]){
            this.rules[i] = 1;
          }
      }
      this.onUpdate();
    }).bind(this));
};

oop.inherits(Worker, Mirror);

(function() {
    
    CSSLint.addRule({
        
        id: "ruleinfo",
        //initialization
        init: function(parser, reporter){
            parser.addListener("startrule", function(e){
                reporter.info(e.selectors.map(function(s){return s.text.toLowerCase()}).join(","), e.line, e.col, "ruleinfo");
            });
        }

    });
    
    this.updateStats = function(){
        var value = this.doc.getValue();
        var stats = getStats(value);
        json = JSON.stringify(stats);
        if(json == this.previousStats){
            return
        }
        this.previousStats = json
        this.sender.emit("cssstats", stats);
        this.statsTimeout = 0;
    };
    
    this.onUpdate = function() {
        var value = this.doc.getValue();
        this.rules['ruleinfo'] = 1;
        result = CSSLint.verify(value, this.rules);
        var rules = []
        var messages = []
        for (var i=0; i<result.messages.length; i++){
            var rule = result.messages[i];
            if(rule.type == "info" && rule.rule == "ruleinfo"){
                rules.push({selector:rule.message.replace(/\s+/g, " "), line:rule.line});
            }
            else messages.push(rule);
        }
      
        this.sender.emit("outline", rules);
        this.sender.emit("csslint", messages.map(function(msg) {
            delete msg.rule;
            return msg;
        }));
        
        if(this.statsTimeout){
            clearTimeout(this.statsTimeout);
        }
        this.statsTimeout = setTimeout(this.updateStats, this.previousStats==null?600:6000);
    };
    
}).call(Worker.prototype);

});