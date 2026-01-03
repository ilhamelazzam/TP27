package com.example.pricingservice.web;

import org.springframework.web.bind.annotation.*;

import java.util.concurrent.ThreadLocalRandom;

@RestController
@RequestMapping("/api/prices")
public class PricingController {

    @GetMapping("/{bookId}")
    public double price(@PathVariable long bookId,
                        @RequestParam(name = "fail", defaultValue = "false") boolean fail) {

        if (fail) {
            throw new IllegalStateException("Pricing down (forced)");
        }

        if (ThreadLocalRandom.current().nextInt(100) < 30) {
            throw new IllegalStateException("Random failure");
        }

        return 50.0 + (bookId % 10) * 5.0;
    }
}