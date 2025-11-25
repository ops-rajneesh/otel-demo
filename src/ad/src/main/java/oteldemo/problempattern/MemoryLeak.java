package oteldemo.problempattern;

import java.util.ArrayList;
import java.util.List;

public class MemoryLeak {

        private static final List<Object> leakyList = new ArrayList<>();

    public static void createMemoryLeak() {
       
            // Create new objects and add them to the static list
            leakyList.add(new byte[1024 * 1024]); // 1MB per iteration

            // Sleep a bit to slow down the leak for observation
           
    }
}
