/*
 * Copyright (c) Citrix Systems, Inc.
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 
 *   1) Redistributions of source code must retain the above copyright
 *      notice, this list of conditions and the following disclaimer.
 * 
 *   2) Redistributions in binary form must reproduce the above
 *      copyright notice, this list of conditions and the following
 *      disclaimer in the documentation and/or other materials
 *      provided with the distribution.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */

package com.xensource.xenapi.samples;

import java.lang.Thread.State;
import java.net.URL;
import java.util.Date;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

import com.xensource.xenapi.*;
import com.xensource.xenapi.Host.Record;

/**
 * Demonstrates how a Session object can be shared between multiple Connections.
 */
public class SessionReuse extends TestBase {
    private static boolean threadExit = false;

    public String getTestName() {
        return "SessionReuse";
    }

    protected void TestCore() {

    }

    @Override
    public void RunTest(FileLogger logger, TargetServer server) throws Exception {
        this.logger = logger;

        URL url = new URL("https://" + server.Hostname);

        // Create a Connection. No login is performed for us.
        final Connection connection1 = new Connection(url);
        final double TIMEOUT_SEC = 30;

        try {
            // Create a new Session, whose reference is stored in the Connection.
            Session.loginWithPassword(connection1, server.Username, server.Password, "");

            // Re-use the Session in a second Connection object
            Connection connection2 = new Connection(url, connection1.getSessionReference());

            // Listen for events using the first Connection.
            Thread listener = new Thread(() -> {
                try {
                    Set<String> eventTypes = new HashSet<>();
                    eventTypes.add("*");

                    String token = "";

                    EventBatch eventBatch = Event.from(connection, eventTypes, token, TIMEOUT_SEC);

                    if (threadExit) {
                        // We took too long to get the event, and the test will already have failed.
                        // Exit now, rather than spamming the logs.
                        return;
                    }

                    log("Received " + eventBatch.events.size() + " Event(s). First Event follows.");

                    if (!eventBatch.events.isEmpty()) {
                        log(eventBatch.events.iterator().next().toString());
                    }
                }
                catch (Exception e) {
                    log("Event listener thread got an Exception");
                    log(e.toString());
                }
            });
            listener.start();

            // Wait a bit for other thread to start listening
            Thread.sleep(15000);

            // Cause an event to be generated on the second thread.
            Map<Host, Record> hosts = Host.getAllRecords(connection2);
            if (!hosts.isEmpty())
                hosts.keySet().iterator().next().setNameDescription(connection2, "Set by SessionReuse.java at " + new Date());

            listener.join(60000L);

            threadExit = true;

            if (listener.getState() != State.TERMINATED) {
                throw new IllegalStateException("Listener thread failed to terminate after 60 seconds");
            }
        }
        finally {
            Session.logout(connection1);
        }
    }
}
